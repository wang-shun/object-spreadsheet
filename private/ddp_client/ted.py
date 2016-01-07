import time
from scapy.all import *

probe = False

def arp_display(pkt):
  if probe:
    if pkt[ARP].op == 1: #who-has (request)
      if pkt[ARP].psrc == '0.0.0.0': # ARP Probe
        print "ARP Probe from: " + pkt[ARP].hwsrc
  if pkt[ARP].hwsrc == "00:bb:3a:41:4e:7c":
    print time.ctime(), "Pushed Gerber"
    os.system("coffee private/ddp_client/dash.coffee")

print sniff(prn=arp_display, filter="arp", store=0) #, count=10)
