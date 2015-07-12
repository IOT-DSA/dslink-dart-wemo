import "package:upnp/upnp.dart";

main() async {
  var discovered = new DiscoveredDevice()..location = "http://192.168.2.8:49154/setup.xml";
  var device = await discovered.getRealDevice();
  print(await (await device.getService("urn:Belkin:service:basicevent:1")).invokeAction("SetBinaryState", {
    "BinaryState": 0
  }));
}
