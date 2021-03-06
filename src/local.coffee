# Copyright (c) 2012 clowwindy
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


net = require("net")
fs = require("fs")
path = require("path")
utils = require('./utils')
inet = require('./inet')
Encryptor = require("./encrypt").Encryptor

inetNtoa = (buf) ->
  buf[0] + "." + buf[1] + "." + buf[2] + "." + buf[3]
inetAton = (ipStr) ->
  parts = ipStr.split(".")
  unless parts.length is 4
    null
  else
    buf = new Buffer(4)
    i = 0

    while i < 4
      buf[i] = +parts[i]
      i++
    buf

connections = 0

createServer = (serverAddr, serverPort, port, key, method, timeout)->
  
  getServer = ->
    if serverAddr instanceof Array
      serverAddr[Math.floor(Math.random() * serverAddr .length)]
    else
      serverAddr
     
  server = net.createServer((connection) ->
    connections += 1
    encryptor = new Encryptor(key, method)
    stage = 0
    headerLength = 0
    remote = null
    cachedPieces = []
    addrLen = 0
    remoteAddr = null
    remotePort = null
    addrToSend = ""
    utils.debug "connections: #{connections}"
    clean = ->
      utils.debug "clean"
      connections -= 1
      remote = null
      connection = null
      encryptor = null
      utils.debug "connections: #{connections}"

    connection.on "data", (data) ->
      utils.log utils.EVERYTHING, "connection on data"
      if stage is 5
        # pipe sockets
        data = encryptor.encrypt data
        connection.pause()  unless remote.write(data)
        return
      if stage is 0
        tempBuf = new Buffer(2)
        tempBuf.write "\u0005\u0000", 0
        connection.write tempBuf
        stage = 1
        utils.debug "stage = 1"
        return
      if stage is 1
        try
          # +----+-----+-------+------+----------+----------+
          # |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
          # +----+-----+-------+------+----------+----------+
          # | 1  |  1  | X'00' |  1   | Variable |    2     |
          # +----+-----+-------+------+----------+----------+
  
          #cmd and addrtype
          cmd = data[1]
          addrtype = data[3]
          unless cmd is 1
            utils.error "unsupported cmd: " + cmd
            reply = new Buffer("\u0005\u0007\u0000\u0001", "binary")
            connection.end reply
            return
          if addrtype is 3
            addrLen = data[4]
          else unless addrtype in [1, 4]
            utils.error "unsupported addrtype: " + addrtype
            connection.destroy()
            return
          addrToSend = data.slice(3, 4).toString("binary")
          # read address and port
          if addrtype is 1
            remoteAddr = inetNtoa(data.slice(4, 8))
            addrToSend += data.slice(4, 10).toString("binary")
            remotePort = data.readUInt16BE(8)
            headerLength = 10
          else if addrtype is 4
            remoteAddr = inet.inet_ntop(data.slice(4, 20))
            addrToSend += data.slice(4, 22).toString("binary")
            remotePort = data.readUInt16BE(20)
            headerLength = 22
          else
            remoteAddr = data.slice(5, 5 + addrLen).toString("binary")
            addrToSend += data.slice(4, 5 + addrLen + 2).toString("binary")
            remotePort = data.readUInt16BE(5 + addrLen)
            headerLength = 5 + addrLen + 2
          buf = new Buffer(10)
          buf.write "\u0005\u0000\u0000\u0001", 0, 4, "binary"
          buf.write "\u0000\u0000\u0000\u0000", 4, 4, "binary"
          # 2222 can be any number between 1 and 65535
          buf.writeInt16BE 2222, 8
          connection.write buf
          # connect remote server
          aServer = getServer()
          remote = net.connect(serverPort, aServer, ->
            utils.info "connecting #{remoteAddr}:#{remotePort}"
            if not encryptor
              remote.destroy() if remote
              return
            addrToSendBuf = new Buffer(addrToSend, "binary")
            addrToSendBuf = encryptor.encrypt addrToSendBuf
            remote.write addrToSendBuf
            i = 0
  
            while i < cachedPieces.length
              piece = cachedPieces[i]
              piece = encryptor.encrypt piece
              remote.write piece
              i++
            cachedPieces = null # save memory
            stage = 5
            utils.debug "stage = 5"
          )
          remote.on "data", (data) ->
            utils.log utils.EVERYTHING, "remote on data"
            try
              if encryptor
                data = encryptor.decrypt data
                remote.pause()  unless connection.write(data)
              else
                remote.destory()
            catch e
              utils.error e
              remote.destroy() if remote
              connection.destroy() if connection
  
          remote.on "end", ->
            utils.debug "remote on end"
            connection.end() if connection
  
          remote.on "error", (e)->
            utils.debug "remote on error"
            utils.error "remote #{remoteAddr}:#{remotePort} error: #{e}"

          remote.on "close", (had_error)->
            utils.debug "remote on close:#{had_error}"
            if had_error
              connection.destroy() if connection
            else
              connection.end() if connection
  
          remote.on "drain", ->
            utils.debug "remote on drain"
            connection.resume()
  
          remote.setTimeout timeout, ->
            utils.debug "remote on timeout"
            remote.destroy() if remote
            connection.destroy() if connection
  
          if data.length > headerLength
            buf = new Buffer(data.length - headerLength)
            data.copy buf, 0, headerLength
            cachedPieces.push buf
            buf = null
          stage = 4
          utils.debug "stage = 4"
        catch e
          # may encounter index out of range
          utils.error e
          connection.destroy() if connection
          remote.destroy() if remote
      else cachedPieces.push data  if stage is 4
        # remote server not connected
        # cache received buffers
        # make sure no data is lost
  
    connection.on "end", ->
      utils.debug "connection on end"
      remote.end()  if remote
  
    connection.on "error", (e)->
      utils.debug "connection on error"
      utils.error "local error: #{e}"

    connection.on "close", (had_error)->
      utils.debug "connection on close:#{had_error}"
      if had_error
        remote.destroy() if remote
      else
        remote.end() if remote
      clean()
  
    connection.on "drain", ->
      # calling resume() when remote not is connected will crash node.js
      utils.debug "connection on drain"
      remote.resume() if remote and stage is 5
  
    connection.setTimeout timeout, ->
      utils.debug "connection on timeout"
      remote.destroy() if remote
      connection.destroy() if connection
  )
  server.listen port, ->
    utils.info "server listening at port " + port
  
  server.on "error", (e) ->
    if e.code is "EADDRINUSE"
      utils.error "Address in use, aborting"
    else
      utils.error e
    
  return server

exports.createServer = createServer
exports.main = ->  
  console.log(utils.version)
  configFromArgs = utils.parseArgs()
  configPath = 'config.json'
  if configFromArgs.config_file
    configPath = configFromArgs.config_file
  if not fs.existsSync(configPath)
    configPath = path.resolve(__dirname, "config.json")
    if not fs.existsSync(configPath)
      configPath = path.resolve(__dirname, "../../config.json")
      if not fs.existsSync(configPath)
        configPath = null
  if configPath
    utils.info 'loading config from ' + configPath
    configContent = fs.readFileSync(configPath)
    config = JSON.parse(configContent)
  else
    config = {}
  for k, v of configFromArgs
    config[k] = v
  if config.verbose
    utils.config(utils.DEBUG)
  SERVER = config.server
  REMOTE_PORT = config.server_port
  PORT = config.local_port
  KEY = config.password
  METHOD = config.method
  if not (SERVER and REMOTE_PORT and PORT and KEY)
    utils.warn 'config.json not found, you have to specify all config in commandline'
    process.exit 1
  timeout = Math.floor(config.timeout * 1000) or 600000
  s = createServer SERVER, REMOTE_PORT, PORT, KEY, METHOD, timeout
  s.on "error", (e) ->
    process.stdout.on 'drain', ->
      process.exit 1
if require.main is module
  exports.main()
