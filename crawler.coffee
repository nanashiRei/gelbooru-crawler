_ = require "underscore"
util = require "util"
path = require "path"
fs = require "fs"
http = require "http"
url = require "url"

require "colors"

class GelbooruCrawler
  constructor: (query, config) ->
    @baseUrl = config.baseUrl
    @maxWorkers = config.maxWorkers or 5
    @maxDownloads = config.maxDownloads or 4
    @renameFiles = config.renameFiles or true
    @query = query or ""

  baseUrl: null
  browseUrl: "/index.php?page=post&s=list"
  viewUrl: "/index.php?page=post&s=view&id="
  searchUrlBase: null
  crawledImages: []
  resolveQueue: []
  downloadQueue: []
  downloads: []
  workers: {}
  query: null
  galleryName: null
  pageId: null
  running: no
  crawling: no
  downloadPath: null
  totalFiles: 0
  crawls: 0
  workerColors: ['yellow', 'red', 'green', 'blue', 'white', 'cyan', 'magenta']
  imageIdRegExp: /index\.php\?page=post&amp;s=view&amp;id=(\d+)/ig
  imageUrlRegExp:  /http:\/\/cdn\d+.*(\/?images\/\d+\/[a-f0-9]+\.(jpe?g|png|gif))/ig

  log: (worker, message...) ->
    if worker? and worker > -1
      col = worker % (@workerColors.length * 2)
      colId = col % @workerColors.length
      bold = yes if col > @workerColors.length
      out = []
      for mymsg in message
        mymsg = mymsg.bold if bold?
        out.push "[Worker ##{worker.toString()}]"[@workerColors[colId]].bold + " " + mymsg[@workerColors[colId]]
      console.log.apply null, out
    else
      out = []
      for msg in message
        out.push "[>--INFO--<] #{msg.grey}"
      console.log.apply null, out

  search: ->
    tags = @query.split /\s+/
    positive = []
    negative = []
    for tag in tags
      do (tag) =>
        (if tag.charAt(0) == "-" then negative else positive)
          .push tag
            .replace(/\-/g, "not-")
            .replace(/_/g, "-")
            .replace(/[^a-z0-9\-\.]/gi, "")

    @galleryName = positive.join(".") + ".(" + negative.join(".") + ")"
    @createPath()

    @searchUrlBase = "#{ @browseUrl }&tags=#{ escape(@query) }&pid="
    @pageId = 0
    @running = yes
    @crawling = yes

    @log null, "BaseURL: #{@baseUrl}"
    @log null, "Search: #{@query}"
    @log null, " -> include: #{ positive.join ", " }"
    @log null, " -> exclude: #{ negative.join ", " }"
    @log null, "Gallery Name: #{@galleryName}"
    @log null, "Starting crawler ... max. #{@maxWorkers} requests"
    process.nextTick =>
      @crawl.call @

  crawl: ->
    while Object.keys(@workers).length < @maxWorkers
      @crawls++

      if @crawling and not @resolveQueue.length
        @spawnWorker @searchUrlBase + @pageId, @scanPage
        @pageId += 28
      else if @resolveQueue.length
        imageId = @resolveQueue.pop()
        @resolveImageId imageId
      else
        @storeDownloadList =>
          @getDownload.call @

      @log null, "Pass: #{@crawls} Threads: #{@workers.length}/#{@maxWorkers}
       Found: #{@crawledImages.length} images"

  getDownload: ->
    @downloadQueue ?= _.clone @crawledImages
    while @downloads.length < @maxDownloads and @downloadQueue.length
      fileData = @downloadQueue.pop()
      [url, id, viewLink] = fileData
      console.log "[#{id}] #{viewLink} image-url = '#{url}'"

  downloadFile: (uri) ->
    filename = @downloadPath + "/" + path.basename(uri, yes)

  spawnWorker: (uri, callback) ->
    requestUrl = uri
    wid = @crawls
    request = url.parse @baseUrl + requestUrl
    request.agent = no

    @log wid, "Requesting: #{@baseUrl.grey}#{requestUrl}"

    @workers[wid] = http.request request, (response) =>
      @workerResponse.call @, @workers[wid], requestUrl, response, callback

    @workers[wid].__workerId = wid

    @workers[wid].once "error", (err) =>
      @log wid, "Error: " + err.toString().red.bold
      @endWorker.call @, wid

    @workers[wid].once "close", =>
      @log wid, "Finished: #{@baseUrl.grey}#{requestUrl}"
      @endWorker.call @, wid

    @workers[wid].end()

  workerResponse: (worker, uri, res, callback) ->
    wid = worker.__workerId
    @log wid, "Response: #{@baseUrl.grey}#{uri}"
    htmlBody = ""

    res.on "data", (data) =>
      htmlBody += data

    res.once "end", =>
      @log wid, "Processing data: #{@baseUrl.grey}#{uri}"
      callback.call @, worker, htmlBody

    res.once "error", (err) =>
      @log wid, "Error: " + err.toString().red.bold
      @endWorker.call @, wid

  endWorker: (worker) ->
    wid = worker.__workerId
    if wid? and @workers[wid]
      @workers.splice wid, 1
      @log wid, "Worker terminated without errors."

    process.nextTick =>
      @crawl.call @

  scanPage: (worker, html) ->
    didMatch = []
    wid = worker.__workerId

    while image = @imageIdRegExp.exec html
      didMatch.push image[1]
      @resolveQueue.push image[1]

    if not didMatch.length
      @log wid, "No images found. This was the last page. Stopping the crawler!"
      @crawling = no
    else
      @log wid, "Found #{didMatch.length} images, #{@resolveQueue.length} in queue and #{@crawledImages.length} resolved"

  storeDownloadList: (callback) ->
    @log null, "", "", "Storing Download List to file #{@downloadPath}/gallery.json"
    fs.writeFile "#{@downloadPath}/gallery.json"
    , JSON.stringify(@crawledImages, null, "  ")
    , (err) =>
      throw err if err?
      @log null, "Download List stored to #{@downloadPath}/gallery.json"
      if typeof callback == "function"
        callback.call @

  resolveImageId: (id) ->
    @spawnWorker @viewUrl + id, (worker, html) =>
      while image = @imageUrlRegExp.exec html
        if @crawledImages.indexOf(image[0]) is -1
          @crawledImages.push [image[0], id, @viewUrl + id]
        else
          @log worker.__workerId, "Duplicate for ##{id}/#{image[0]} ?!".red.bold
        break

  createPath: ->
    date = new Date()
    @downloadPath = __dirname
    dateLevel = [date.getFullYear(), date.getMonth() + 1, date.getDate()]

    for dlPath in dateLevel
      do (dlPath) =>
        @downloadPath += "/" + dlPath
        fs.mkdir @downloadPath, "0755" if not fs.existsSync @downloadPath

    @downloadPath += "/" + @galleryName
    fs.mkdir @downloadPath, "0755" if not fs.existsSync @downloadPath
    @log null, "Created: #{@downloadPath}".italic

conf =
  baseUrl: "http://gelbooru.com"
  maxDownloads: 6
  maxWorkers: 10
  renameFiles: yes

test = new GelbooruCrawler "no_bra no_pants -huge* -large* -penis -*boy*", conf
test.search()
