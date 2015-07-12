import "dart:async";

import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";

import "package:upnp/upnp.dart";

DeviceDiscoverer discoverer = new DeviceDiscoverer();
LinkProvider link;
SimpleNode devicesNode;

main(List<String> args) async {
  link = new LinkProvider(args, "WeMo-", isResponder: true, command: "run", profiles: {
    "getBinaryState": (String path) => new GetBinaryStateNode(path),
    "setBinaryState": (String path) => new SetBinaryStateNode(path),
    "toggleBinaryState": (String path) => new ToggleBinaryStateNode(path),
    "brewCoffee": (String path) => new BrewCoffeeNode(path),
    "addDevice": (String path) => new SimpleActionNode(path, (Map<String, dynamic> params) async {
      var ip = params["ip"];

      if (ip == null || ip is! String) {
        return {
          "success": false,
          "error": "Bad IP"
        };
      }

      var port = params["port"];

      try {
        if (port is String) {
          port = int.parse(port);
        }

        var dm = new DiscoveredClient();
        dm.location = "http://${ip}:${port}/setup.xml";

        var device = await dm.getDevice();

        await addDevice(device, true);
        await link.saveAsync();
      } catch (e) {
        return {
          "success": false,
          "error": e.toString()
        };
      }

      return {
        "success": true,
        "error": ""
      };
    }),
    "remove": (String path) => new DeleteActionNode.forParent(path, link.provider)
  }, autoInitialize: false);

  link.init();

  link.onValueChange("/Auto_Discovery").listen((_) async {
    await link.saveAsync();
  });

  var m = {
    "Auto_Discovery": {
      r"$name": "Auto Discovery",
      r"$type": "bool[disabled,enabled]",
      "?value": true,
      r"$writable": "write"
    },
    "Value_Tick_Rate": {
      r"$name": "Value Tick Rate",
      r"$type": "number",
      r"$unit": "seconds",
      r"$writable": "write",
      "?value": 2
    },
    "Discovery_Tick_Rate": {
      r"$name": "Discovery Tick Rate",
      r"$type": "number",
      r"$unit": "seconds",
      r"$writable": "write",
      "?value": 30
    },
    "Add_Device": {
      r"$name": "Add Device",
      r"$is": "addDevice",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": [
        {
          "name": "ip",
          "type": "string"
        },
        {
          "name": "port",
          "type": "int",
          "default": 49154
        }
      ],
      r"$columns": [
        {
          "name": "success",
          "type": "bool"
        },
        {
          "name": "error",
          "type": "string"
        }
      ]
    }
  };

  for (var n in m.keys) {
    if (!link.provider.nodes.containsKey("/${n}")) {
      link.addNode("/${n}", m[n]);
    }
  }

  devicesNode = link["/"];

  link.onValueChange("/Value_Tick_Rate").listen((ValueUpdate update) async {
    var value = update.value;

    if (value is String) {
      value = int.parse(value);
    }

    valueUpdateTickRate = new Duration(seconds: value);

    if (valueUpdateTimer != null) {
      valueUpdateTimer.cancel();
      valueUpdateTimer = null;
    }

    valueUpdateTimer = new Timer.periodic(valueUpdateTickRate, (timer) async {
      await tickValueUpdates();
    });

    await link.saveAsync();
  });

  link.onValueChange("/Discovery_Tick_Rate").listen((ValueUpdate update) async {
    var value = update.value;

    if (value is String) {
      value = int.parse(value);
    }

    deviceDiscoveryTickRate = new Duration(seconds: value);

    if (discoveryTimer != null) {
      discoveryTimer.cancel();
      discoveryTimer = null;
    }

    discoveryTimer = new Timer.periodic(deviceDiscoveryTickRate, (timer) async {
      await tickDeviceDiscovery();
    });

    await link.saveAsync();
  });

  await updateDevices();

  link.syncValue("/Value_Tick_Rate");
  link.syncValue("/Discovery_Tick_Rate");
  link.connect();
}

Timer valueUpdateTimer;
Timer discoveryTimer;

updateDevices() async {
  if (link.val("/Auto_Discovery_Enabled") != true) {
    return;
  }

  List<Device> devices;

  try {
    devices = await discoverer.getDevices(type: CommonDevices.WEMO).timeout(new Duration(seconds: 15), onTimeout: () {
      return [];
    });
  } catch (e) {
    return;
  }

  // Check to see if any devices have been removed.
  for (var c in devicesNode.children.keys.toList()) {
    if (devices.any((it) => it.uuid == c)) {
      continue;
    }

    devicesNode.removeChild(c);
  }

  for (Device device in devices) {
    if (
      (link.provider as NodeProviderImpl).nodes.containsKey("/${device.uuid}") &&
      link["/${device.uuid}"].children.containsKey("BinaryState")) {
      continue;
    }

    print("Discovered Device: ${device.friendlyName}");

    await addDevice(device);
  }
}

addDevice(Device device, [bool manual = false]) async {
  if (
    (link.provider as NodeProviderImpl).nodes.containsKey("/${device.uuid}") &&
    link["/${device.uuid}"].children.containsKey("BinaryState")) {
    throw "Device already added.";
  }

  var m = {
    r"$name": device.friendlyName,
    r"$uuid": device.uuid
  };

  var basicEventService = await device.getService("urn:Belkin:service:basicevent:1");

  try {
    var deviceEventService = await device.getService("urn:Belkin:service:deviceevent:1");
    deviceEventServices["/${device.uuid}"] = deviceEventService;
  } catch (e) {
  }

  basicEventServices["/${device.uuid}"] = basicEventService;

  if (manual) {
    m["Remove"] = {
      r"$invokable": "write",
      r"$is": "remove",
      r"$result": "values"
    };
  }

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
    r"$result": "values",
    r"$columns": [
      {
        "name": "state",
        "type": "int"
      }
    ]
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

    m["Brew_Coffee"] = {
      r"$name": "Brew Coffee",
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
  link.addNode("/${device.uuid}", m);
  SimpleNode n = link["/${device.uuid}"];
  n.serializable = manual;
}

Duration deviceDiscoveryTickRate;
Duration valueUpdateTickRate;

tickDeviceDiscovery() async {
  await updateDevices();
}

tickValueUpdates() async {
  for (var path in basicEventServices.keys) {
    var node = link[path];
    var service = basicEventServices[path];
    var result;
    try  {
      result = await service.invokeAction("GetBinaryState", {});
    } catch (e) {
      continue;
    }
    var state = int.parse(result["BinaryState"]);
    node.getChild("BinaryState").updateValue(state);

    var deviceEventService = deviceEventServices[path];

    if (node.getConfig(r"$isCoffeeMaker") == true) {
      var mr;
      try {
        mr = await deviceEventService.invokeAction("GetAttributes", {});
      } catch (e) {
        continue;
      }
      var attrs = WemoHelper.parseAttributes(mr["attributeList"]);
      var mode = CoffeeMakerHelper.getModeString(attrs["Mode"]);
      var brewTimestamp = attrs["Brewed"];
      var brewingTimestamp = attrs["Brewing"];

      if (brewingTimestamp == null) brewingTimestamp = 0;
      if (brewTimestamp == null) brewTimestamp = 0;

      DateTime lastBrewed = new DateTime.fromMillisecondsSinceEpoch(brewTimestamp * 1000);
      DateTime lastBrewStarted = new DateTime.fromMillisecondsSinceEpoch(brewingTimestamp * 1000);
      node.getChild("Mode").updateValue(mode);
      node.getChild("Brew_Completed").updateValue(brewTimestamp == 0 ? "N/A" : lastBrewed.toString());
      node.getChild("Brew_Started").updateValue(brewingTimestamp == 0 ? "N/A" : lastBrewStarted.toString());
      node.getChild("Brew_Duration").updateValue(lastBrewed.difference(lastBrewStarted).inSeconds);
      var age = 0;
      if (brewTimestamp != 0) {
        age = lastBrewed.difference(new DateTime.now()).inSeconds;
      }
      node.getChild("Brew_Age").updateValue(age);
    }
  }
}

class GetBinaryStateNode extends SimpleNode {
  GetBinaryStateNode(String path) : super(path, link.provider);

  @override
  onInvoke(Map params) async {
    var p = path.split("/").take(2).join("/");
    var result;
    try {
      result = await basicEventServices[p].invokeAction("GetBinaryState", {});
    } catch (e) {
      return;
    }
    var state = int.parse(result["BinaryState"]);
    link.val("${p}/BinaryState", state);

    return {
      "state": state
    };
  }
}

class ToggleBinaryStateNode extends SimpleNode {
  ToggleBinaryStateNode(String path) : super(path, link.provider);

  @override
  onInvoke(Map params) {
    var p = path.split("/").take(2).join("/");
    var service = basicEventServices[p];
    service.invokeAction("GetBinaryState", {}).then((result) {
      var state = int.parse(result["BinaryState"]);
      return service.invokeAction("SetBinaryState", {
        "BinaryState": state == 0 ? 1 : 0
      });
    }).catchError((e) {
    });
    return {};
  }
}

class BrewCoffeeNode extends SimpleNode {
  BrewCoffeeNode(String path) : super(path, link.provider);

  @override
  onInvoke(Map params) {
    var p = path.split("/").take(2).join("/");
    var service = deviceEventServices[p];
    service.invokeAction("SetAttributes", {
      "attributeList": CoffeeMakerHelper.createSetModeAttributes(4)
    }).catchError((e) {
    });
    return {};
  }
}

class SetBinaryStateNode extends SimpleNode {
  SetBinaryStateNode(String path) : super(path, link.provider);

  @override
  onInvoke(Map params) async {
    if (params["state"] == null) {
      return {};
    }

    var state = params["state"] is String ? int.parse(params["state"]) : params["state"];

    state = state.toInt();

    var p = path.split("/").take(2).join("/");
    var service = basicEventServices[p];
    return service.invokeAction("SetBinaryState", {
      "BinaryState": state
    }).then((_) {
      return {};
    }).catchError((e) {
    });
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
