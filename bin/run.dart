import "dart:async";

import "package:dslink/client.dart";
import "package:dslink/responder.dart";

import "package:upnp/upnp.dart";

DeviceDiscoverer discoverer = new DeviceDiscoverer();
LinkProvider link;
SimpleNode devicesNode;

main(List<String> args) async {
  link = new LinkProvider(args, "WeMo", isResponder: true, command: "run", defaultNodes: {
    "Devices": {
    }
  }, profiles: {
    "getBinaryState": (String path) => new GetBinaryStateNode(path),
    "setBinaryState": (String path) => new SetBinaryStateNode(path),
    "toggleBinaryState": (String path) => new ToggleBinaryStateNode(path),
    "brewCoffee": (String path) => new BrewCoffeeNode(path)
  });

  if (link.link == null) return;

  devicesNode = link.provider.getNode("/Devices");

  new Timer.periodic(valueUpdateTickRate, (timer) async {
    await tickValueUpdates();
  });

  new Timer.periodic(deviceDiscoveryTickRate, (timer) async {
    await tickDeviceDiscovery();
  });

  await updateDevices();
  link.connect();
}

updateDevices() async {
  List<Device> devices = await discoverer.getDevices(type: CommonDevices.WEMO).timeout(new Duration(seconds: 10), onTimeout: () {
    return [];
  });

  // Check to see if any devices have been removed.
  for (var c in devicesNode.children.keys.toList()) {
    if (devices.any((it) => it.uuid == c)) {
      continue;
    }

    devicesNode.removeChild(c);
  }

  for (Device device in devices) {
    if (link.provider.nodes.containsKey("/Devices/${device.uuid}")) {
      continue;
    }

    print("Discovered Device: ${device.friendlyName}");
    var m = {
      r"$name": device.friendlyName,
      r"$uuid": device.uuid
    };

    if (device.icons != null && device.icons.isNotEmpty) {
      print(device.icons);
      var icon = device.icons.first;
      m[r"$icon"] = icon.url;
    }

    var basicEventService = await device.getService("urn:Belkin:service:basicevent:1");
    var deviceEventService = await device.getService("urn:Belkin:service:deviceevent:1");
    basicEventServices["/Devices/${device.uuid}"] = basicEventService;
    deviceEventServices["/Devices/${device.uuid}"] = deviceEventService;

    m["BinaryState"] = {
      r"$type": "int",
      r"$name": "Binary State"
    };

    m["Model_Name"] = {
      r"$type": "string",
      r"$name": "Model Name",
      r"?value": device.modelName
    };

    m["Manufacturer"] = {
      r"$type": "string",
      r"?value": device.manufacturer,
    };

    m["BinaryState"]["Get"] = {
      r"$is": "getBinaryState",
      r"$invokable": "read",
      r"$result": "values"
    };

    m["BinaryState"]["Set"] = {
      r"$is": "setBinaryState",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": [
        {
          "name": "state",
          "type": "int"
        }
      ],
      r"$columns": {}
    };

    m["BinaryState"]["Toggle"] = {
      r"$is": "toggleBinaryState",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": {},
      r"$columns": {}
    };

    if (device.modelName == "CoffeeMaker") {
      m[r"$isCoffeeMaker"] = true;

      m["Mode"] = {
        r"$type": "string",
        "?value": "Unknown"
      };

      m["Brew Coffee"] = {
        r"$is": "brewCoffee",
        r"$invokable": "write",
        r"$columns": {},
        r"$params": {},
        r"result": "values"
      };

      m["Brew_Started"] = {
        r"$name": "Brew Started",
        r"$type": "string",
        "?value": "Unknown"
      };

      m["Brew_Completed"] = {
        r"$name": "Brew Completed",
        r"$type": "string",
        "?value": "Unknown"
      };

      m["Brew_Duration"] = {
        r"$name": "Brew Duration",
        r"$type": "int",
        "?value": -1
      };

      m["Brew_Age"] = {
        r"$name": "Brew Age",
        r"$type": "int",
        "?value": -1
      };
    } else {
      m[r"$isCoffeeMaker"] = false;
    }
    link.provider.addNode("/Devices/${device.uuid}", m);
  }
}

Duration deviceDiscoveryTickRate = new Duration(seconds: 20);
Duration valueUpdateTickRate = new Duration(seconds: 3);

tickDeviceDiscovery() async {
  await updateDevices();
}

tickValueUpdates() async {
  for (var path in basicEventServices.keys) {
    var node = link.provider.getNode(path);
    var service = basicEventServices[path];
    var result = await service.invokeAction("GetBinaryState", {});
    var state = int.parse(result["BinaryState"]);
    node.getChild("BinaryState").updateValue(state);

    var deviceEventService = deviceEventServices[path];

    if (node.getConfig(r"$isCoffeeMaker")) {
      var mr = await deviceEventService.invokeAction("GetAttributes", {});
      var attrs = WemoHelper.parseAttributes(mr["attributeList"]);
      var mode = CoffeeMakerHelper.getModeString(attrs["Mode"]);
      var brewTimestamp = attrs["Brewed"];
      var brewingTimestamp = attrs["Brewing"];
      DateTime lastBrewed = new DateTime.fromMillisecondsSinceEpoch(brewTimestamp * 1000);
      DateTime lastBrewStarted = new DateTime.fromMillisecondsSinceEpoch(brewingTimestamp * 1000);
      node.getChild("Mode").updateValue(mode);
      node.getChild("Brew_Completed").updateValue(lastBrewed.toString());
      node.getChild("Brew_Started").updateValue(lastBrewStarted.toString());
      node.getChild("Brew_Duration").updateValue(lastBrewed.difference(lastBrewStarted).inSeconds);
      node.getChild("Brew_Age").updateValue(new DateTime.now().difference(lastBrewed).inSeconds);
    }
  }
}

class GetBinaryStateNode extends SimpleNode {
  GetBinaryStateNode(String path) : super(path);

  @override
  onInvoke(Map params) {
    new Future(() async {
      var p = path.split("/").take(3).join("/");
      var result = await basicEventServices[p].invokeAction("GetBinaryState", {});
      var state = int.parse(result["BinaryState"]);
      (link.provider.getNode(p).getChild("BinaryState") as SimpleNode).updateValue(state);
    });

    return {};
  }
}

class ToggleBinaryStateNode extends SimpleNode {
  ToggleBinaryStateNode(String path) : super(path);

  @override
  onInvoke(Map params) {
    var p = path.split("/").take(3).join("/");
    var service = basicEventServices[p];
    service.invokeAction("GetBinaryState", {}).then((result) {
      var state = int.parse(result["BinaryState"]);
      service.invokeAction("SetBinaryState", {
        "BinaryState": state == 0 ? 1 : 0
      });
    });
    return {};
  }
}

class BrewCoffeeNode extends SimpleNode {
  BrewCoffeeNode(String path) : super(path);

  @override
  onInvoke(Map params) {
    var p = path.split("/").take(3).join("/");
    var service = deviceEventServices[p];
    service.invokeAction("SetAttributes", {
      "attributeList": CoffeeMakerHelper.createSetModeAttributes(4)
    }).then((_) {
      print("Brew Coffee Called");
    });
    return {};
  }
}

class SetBinaryStateNode extends SimpleNode {
  SetBinaryStateNode(String path) : super(path);

  @override
  onInvoke(Map params) {
    if (!params.containsKey("state")) {
      return {};
    }

    if (params["state"] == null || params["state"] is! int) {
      return {};
    }

    var p = path.split("/").take(3).join("/");
    basicEventServices[p].invokeAction("SetBinaryState", {
      "BinaryState": params["state"]
    });

    return {};
  }
}

Map<String, Service> basicEventServices = {};
Map<String, Service> deviceEventServices = {};

class CoffeeMakerHelper {
  static String getModeString(mode) {
    if (mode is String) {
      mode = int.parse(mode);
    }
    return {
      0: "Refill",
      1: "Place Carafe",
      2: "Refill Water",
      3: "Ready",
      4: "Brewing",
      5: "Brewed",
      6: "Cleaning: Brewing",
      7: "Cleaning: Soaking",
      8: "Brew Failed: Carafe Removed"
    }[mode];
  }

  static String createSetModeAttributes(int mode) {
    return WemoHelper.encodeAttributes({
      "Brewed": "NULL",
      "LastCleaned": "NULL",
      "ModeTime": "NULL",
      "Brewing": "NULL",
      "TimeRemaining": "NULL",
      "WaterLevelReached": "NULL",
      "Mode": mode,
      "CleanAdvise": "NULL",
      "FilterAdvise": "NULL",
      "Cleaning": "NULL"
    });
  }
}
