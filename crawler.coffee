_ = require "underscore"
util = require "util"
path = require "path"
fs = require "fs"
http = require "http"

require "colors"

class GelbooruCrawler
  constructor: (query, config) ->
    @baseUrl = config.baseUrl
    @maxWorkers = config.maxWorkers or 5
    @maxDownloads = config.maxDownloads or 4
    @renameFiles = config.renameFiles or true
    @query = query or ""

  @::baseUrl = null
  @::browseUrl = "/index.php?page=post&s=list"
  @::viewUrl = "/index.php?page=post&s=view&id="
  @::searchUrlBase = null
  @::crawledImages = []
  @::resolveQueue = []
  @::workers = []
  @::query = null
  @::galleryName = null
  @::pageId = null
  @::running = no
  @::crawling = no
  @::downloadPath = null
  @::totalFiles = 0
  @::crawls = 0
  @::workerColors = ['yellow', 'red', 'green', 'blue', 'white', 'cyan', 'magenta']

  @::imageIdRegExp = /index\.php\?page=post&amp;s=view&amp;id=(\d+)/ig
  @::imageUrlRegExp =  /http:\/\/cdn\d+.*(\/?images\/\d+\/[a-f0-9]+\.(jpe?g|png|gif))/ig

  log: (worker, message...) ->
    w = @workers.indexOf worker if worker?
    if w? and w isnt -1
      col = w % (@workerColors.length * 2)
      colId = col % @workerColors.length
      bold = yes if col > @workerColors.length
      out = []
      for mymsg in message
        mymsg = mymsg.bold if bold?
        out.push mymsg[@workerColors[colId]]
      util.log.apply null, out
    else
      util.log.apply null, message

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
            .replace(/[^a-z\-]/gi, "")

    @galleryName = positive.join(", ") + " (" + negative.join(", ") + ")"
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
      @crawl()

  crawl: ->
    while @workers.length < @maxWorkers
      @crawls++
      if @crawling and not @resolveQueue.length
        @spawnWorker @searchUrlBase + @pageId, @scanPage
        @pageId += 28
      else if @resolveQueue.length
        imageId = @resolveQueue.pop()
        @resolveImageId imageId
      @log null, "Pass: #{@crawls} Threads: #{@workers.length}/#{@maxWorkers}".underline
      @log null, "Found: #{@crawledImages.length} images".underline
    process.nextTick =>
      crawl = => @crawl()
      (setTimeout crawl, 2000) if @crawling or @resolveQueue.length

  downloadImage: (url) ->
    filename = @downloadPath + "/" + path.basename(url, yes)

  spawnWorker: (url, callback) ->
    requestUrl = url
    @log @workers.length, "Spawning worker for: #{requestUrl}"
    worker = http.get @baseUrl + requestUrl, (response) =>
      @workerResponse worker, requestUrl, response, callback
    worker.on "error", (error) =>
      w = @workers.indexOf worker
      @log w, "Error in #{w}: " + error.toString()
    @workers.push worker

  workerResponse: (worker, url, httpResponse, callback) ->
    workerId = @workers.indexOf worker
    @log workerId, "Worker ##{workerId} created for #{url}"
    htmlBody = ""
    httpResponse.on "data", (data) =>
      htmlBody += data
    httpResponse.on "end", =>
      @log workerId, "Worker ##{workerId} processing data : [#{url}]"
      callback.call @, worker, htmlBody
      @endWorker.call @, worker
    httpResponse.on "error", (err) =>
      @log workerId, "Error in Worker ##{workerId}: " + err.toString() + " : [#{url}]"
      @endWorker.call @, worker

  endWorker: (worker) ->
    w = @workers.indexOf worker
    if w isnt -1
      @workers.splice w, 1
      @log w, "Worker ##{w} ended."

  scanPage: (worker, html) ->
    didMatch = []
    w = @workers.indexOf worker
    while image = @imageIdRegExp.exec html
      didMatch.push image[1]
      @resolveQueue.push image[1]
    if not didMatch.length
      @log w, "No images found. This was the last page. Stopping the crawler!"
      @crawling = no
      @storeDownloadList()
    else
      @log w, "Images found: " + didMatch.join(", ")

  storeDownloadList: ->
    fs.writeFile "#{@downloadPath}/gallery.json", JSON.stringify(@crawledImages, null, "  "), "utf-8"

  resolveImageId: (id) ->
    @spawnWorker @viewUrl + id, (worker, html) =>
      while image = @imageUrlRegExp.exec html
        if @crawledImages.indexOf(image[0]) is -1
          @crawledImages.push [image[0], id, @viewUrl + id]
          #@log null, "Resolved image ##{id} to '#{image[0]}'"
        else
          @log null, "Duplicate for ##{id}/#{image[0]} ?!".italic
        break
      #@workers.splice @workers.indexOf(req), 1

  createPath: ->
    date = new Date()
    @downloadPath = __dirname
    dateLevel = [date.getFullYear(), date.getMonth() + 1, date.getDate()]

    for dlPath in dateLevel
      do (dlPath) =>
        @downloadPath += "/" + dlPath
        fs.mkdir @downloadPath, 755 if not fs.existsSync @downloadPath

    @downloadPath += "/" + @galleryName
    fs.mkdir @downloadPath, 755 if not fs.existsSync @downloadPath
    @log null, "Created: #{@downloadPath}".italic

conf =
  baseUrl: "http://gelbooru.com"
  maxDownloads: 6
  maxWorkers: 5
  renameFiles: yes

test = new GelbooruCrawler "no_bra no_pants -huge* -large* -penis -*boy*", conf
test.search()
