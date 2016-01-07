DDPClient = require("ddp")
pcap = require('pcap') #./node_pcap/pcap')


ddp = new DDPClient({})

class Tablespace
    constructor: (@id) ->

    typeName: -> 'Tablespace'
    toJSONValue: -> {@id}
    @fromJSONValue: (json) => new Tablespace(json.id)

ddp.EJSON.addType('Tablespace', Tablespace.fromJSONValue)


ddp.connect (error, wasReconnect) ->
    if (error)
        console.log "error: " + error
    else
        console.log wasReconnect


dashRequest = ->
  call = [new Tablespace("milk"), "dashButtonRequest", {}]
  ddp.call "executeCannedTransaction", call, (err, result) ->
      if err
          console.log "error: " + JSON.stringify(err)
      console.log result



pcap_session = pcap.createSession('en0', 'arp')

fmt_ip = (addr) -> addr.join(".")
fmt_byte = (b) -> ("00" + b.toString(16)).substr(-2)
fmt_mac = (addr) -> addr.map(fmt_byte).join(":")

pcap_session.on 'packet', (raw_packet) ->
    packet = pcap.decode.packet(raw_packet)
    #console.log(util.inspect(packet));
    hwsrc = fmt_mac(packet.payload.shost.addr)
    hwdst = fmt_mac(packet.payload.dhost.addr)
    psrc = fmt_ip(packet.payload.payload.sender_pa.addr)
    if packet.payload.payload.htype == 1  #who-has (request)
        if psrc == "0.0.0.0"
            console.log("ARP Probe from: " + hwsrc)
    if hwsrc == "00:bb:3a:41:4e:7c"
      console.log new Date().toLocaleString() + " Pushed Gerber"
      dashRequest()
