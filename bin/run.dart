import "dart:async";
import "dart:io";

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

        await addDevice(device, true, true);
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
    "remove": (String path) => new DeleteActionNode.forParent(
      path,
      link.provider as MutableNodeProvider,
      onDelete: () {
        link.save();
      }
    )
  }, autoInitialize: false);

  link.init();

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
      "?value": 1
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
    if (!(link.provider as NodeProviderImpl).nodes.containsKey("/${n}")) {
      link.addNode("/${n}", m[n]);
    }
  }

  devicesNode = link["/"];

  link.onValueChange("/Auto_Discovery").listen((_) async {
    await link.saveAsync();
  });

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

  for (var n in link["/"].children.keys) {
    SimpleNode nr = link["/${n}"];

    if (!nr.children.containsKey("BinaryState")) {
      continue;
    }

    attemptInitialConnect(n);
  }

  updateDevices();

  link.syncValue("/Value_Tick_Rate");
  link.syncValue("/Discovery_Tick_Rate");
  link.connect();
}

attemptInitialConnect(String n) async {
  SimpleNode nr = link["/${n}"];

  try {
    var devices = await new DeviceDiscoverer().getDevices();
    var device = devices.firstWhere((x) => x.uuid == n, orElse: () => null);

    if (device == null) {
      var dm = new DiscoveredClient();
      dm.location = nr.configs[r"$location"];
    }

    await addDevice(device, true, true);

    print("Connected to ${n}");
  } catch (e) {
    print("Failed to load device: ${n}");
    new Timer(const Duration(seconds: 5), () async {
      if (nr.configs[r"$uuid"] != null) {
        await attemptInitialConnect(n);
      }
    });
  }
}

Timer valueUpdateTimer;
Timer discoveryTimer;

updateDevices() async {
  if (link.val("/Auto_Discovery") != true) {
    return;
  }

  List<Device> devices;

  try {
    devices = await discoverer.getDevices(timeout: const Duration(seconds: 20));
    devices = devices.where((x) =>
      x.services.any(
        (s) => s.type == "urn:Belkin:service:basicevent:1"
      )
    ).toList();
  } catch (e) {
    return;
  }

  // Check to see if any devices have been removed.
  for (var c in devicesNode.children.keys.toList()) {
    if (devices.any((it) => it.uuid == c)) {
      continue;
    }
  }

  for (Device device in devices) {
    if (
      (link.provider as NodeProviderImpl).nodes.containsKey("/${device.uuid}") &&
      link["/${device.uuid}"] != null &&
      link["/${device.uuid}"].configs.containsKey(r"$location")) {
      continue;
    }

    print("Discovered Device: ${device.friendlyName}");

    await addDevice(device);
  }
}

tryToFix(String uuid, String udn) async {
  print("Attempting Reconnection to ${uuid}");
  try {
    var devices = await new DeviceDiscoverer().getDevices(
      type: uuid
    ).timeout(const Duration(seconds: 10), onTimeout: () => []);

    var device = devices.firstWhere((x) => x.uuid == uuid, orElse: () => null);

    if (device == null) {
      print("Reconnection Failed for ${uuid}");
      return false;
    }

    var p = "/${uuid}";
    var services = [
      basicEventServices[p],
      deviceEventServices[p],
      insightServices[p]
    ];
    services.removeWhere((x) => x == null);
    var base = Uri.parse(device.urlBase);

    link[p].configs[r"$location"] = base.toString();
    await link.saveAsync();

    for (Service service in services) {
      var uri = Uri.parse(service.controlUrl);
      uri = uri.replace(host: base.host, port: base.port);
      service.controlUrl = uri.toString();
    }
  } catch (e) {
    print("Reconnection Failed for ${uuid}: ${e}");
    return false;
  }

  print("Reconnected to ${uuid}");

  return true;
}

addDevice(Device device, [bool manual = false, bool force = false]) async {
  print("Added Device ${device.uuid}");

  if (
    (link.provider as NodeProviderImpl).nodes.containsKey("/${device.uuid}") &&
    link["/${device.uuid}"].configs.containsKey(r"$location") && !force) {
    throw "Device already added.";
  }

  var uri = device.url;

  var m = {
    r"$name": device.friendlyName,
    r"$uuid": device.uuid,
    r"$udn": device.udn,
    r"$location": uri
  };

  var basicEventService = await device.getService(
    "urn:Belkin:service:basicevent:1"
  );

  try {
    var deviceEventService = await device.getService(
      "urn:Belkin:service:deviceevent:1"
    );
    deviceEventServices["/${device.uuid}"] = deviceEventService;
  } catch (e) {
  }

  try {
    var insightDeviceService = await device.getService(
      "urn:Belkin:service:insight:1"
    );
    insightServices["/${device.uuid}"] = insightDeviceService;
  } catch (e) {
  }

  basicEventServices["/${device.uuid}"] = basicEventService;

  m["Friendly_Name"] = {
    r"$name": "Friendly Name",
    r"$type": "string"
  };

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
    r"?value": device.manufacturer
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

  if (device.modelName == "Insight") {
    m[r"$isInsightSwitch"] = true;

    m["State"] = {
      r"$type": "enum[On,Off,Standby]",
      "?value": "Unknown"
    };

    m["Last_State_Change"] = {
      r"$name": "Last State Change",
      r"$type": "string"
    };

    m["Current_Power"] = {
      r"$name": "Current Power",
      r"$type": "number",
      r"$unit": "milliwatts"
    };

    m["On_For_Time"] = {
      r"$name": "On For",
      r"$type": "number",
      r"$unit": "seconds",
      r"$precision": 0
    };

    m["On_For_Today"] = {
      r"$name": "On Today",
      r"$type": "number",
      r"$unit": "seconds",
      r"$precision": 0
    };

    m["On_For_Total"] = {
      r"$name": "On Total",
      r"$type": "number",
      r"$unit": "seconds",
      r"$precision": 0
    };

    m["Today_Power"] = {
      r"$name": "Power for Today",
      r"$type": "number",
      r"$unit": "milliwatts"
    };

    m["Total_Power"] = {
      r"$name": "Power Total",
      r"$type": "number",
      r"$unit": "milliwatts"
    };
  } else {
    m[r"$isInsightSwitch"] = false;
  }

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

bool isDiscovering = false;

tickDeviceDiscovery() async {
  if (isDiscovering) {
    return;
  }
  isDiscovering = true;
  await updateDevices();
  isDiscovering = false;
}

List<String> ticking = [];

tickValueUpdates() async {
  for (var path in basicEventServices.keys) {
    if (ticking.contains(path)) {
      return;
    }

    new Future(() async {
      if (ticking.contains(path)) {
        return;
      }

      SimpleNode node = link[path];
      ticking.add(path);

      if (
        !node.children.values.any((SimpleNode x) => x.hasSubscriber) &&
        !(link.val("${path}/BinaryState") == null)) {
        ticking.remove(path);
        return;
      }

      var service = basicEventServices[path];
      var result;
      try  {
        result = await service
          .invokeAction("GetBinaryState", {})
          .timeout(const Duration(seconds: 5));
      } catch (e) {
        if (e is SocketException || e is TimeoutException) {
          var m = await tryToFix(path.substring(1), link[path].configs[r"$udn"]);
          if (!m) {
            ticking.remove(path);
            return;
          }
        } else {
          ticking.remove(path);
          return;
        }
        result = await service.invokeAction("GetBinaryState", {});
      }

      try {
        var friendlyName = (await service.invokeAction("GetFriendlyName", {}))["FriendlyName"];
        link.val("${path}/Friendly_Name", friendlyName);
      } catch (e) {
      }

      var state = int.parse(result["BinaryState"]);
      link.val("${path}/BinaryState", state);

      var deviceEventService = deviceEventServices[path];

      if (node.getConfig(r"$isCoffeeMaker") == true) {
        var mr;
        try {
          mr = await deviceEventService.invokeAction("GetAttributes", {});
        } catch (e) {
          ticking.remove(path);
          return;
        }
        var attrs = WemoHelper.parseAttributes(mr["attributeList"]);
        var mode = CoffeeMakerHelper.getModeString(attrs["Mode"]);
        var brewTimestamp = attrs["Brewed"];
        var brewingTimestamp = attrs["Brewing"];

        if (brewingTimestamp == null) brewingTimestamp = 0;
        if (brewTimestamp == null) brewTimestamp = 0;

        DateTime lastBrewed = new DateTime.fromMillisecondsSinceEpoch(
          brewTimestamp * 1000
        );

        DateTime lastBrewStarted = new DateTime.fromMillisecondsSinceEpoch(
          brewingTimestamp * 1000
        );
        link.val("${path}/Mode", mode);
        link.val("${path}/Brew_Completed", brewTimestamp == 0 ? "N/A" : lastBrewed.toString());
        link.val(
          "${path}/Brew_Started",
          brewingTimestamp == 0 ? "N/A" : lastBrewStarted.toString()
        );
        link.val(
          "${path}/Brew_Duration",
          lastBrewed.difference(lastBrewStarted).inSeconds
        );
        var age = 0;
        if (brewTimestamp != 0) {
          age = lastBrewed.difference(new DateTime.now()).inSeconds;
        }
        link.val("${path}/Brew_Age", age);
      } else if (node.getConfig(r"$isInsightSwitch") == true) {
        var insight = insightServices[path];
        if (insight == null) {
          ticking.remove(path);
          return;
        }

        try {
          var data = await fetchInsightData(insight);
          link.val("${path}/State", data["state"]);
          link.val("${path}/Last_State_Change", data["lastChange"]);
          link.val("${path}/Current_Power", data["power"]);
          link.val("${path}/On_For_Time", data["onForTime"]);
          link.val("${path}/On_For_Today", data["onForToday"]);
          link.val("${path}/On_For_Total", data["onForTotal"]);
          link.val("${path}/Today_Power", data["powerToday"]);
          link.val("${path}/Total_Power", data["powerTotal"]);
        } catch (e) {}
      }

      ticking.remove(path);
    });
  }
}

Future<Map<String, dynamic>> fetchInsightData(Service service) async {
  var result = await service.invokeAction("GetInsightParams", {});
  var p = result["InsightParams"];
  var c = p.split("|");
  var state = {
    "0": "Off",
    "1": "On",
    "8": "Standby"
  }[c[0]];

  var lastChange = new DateTime.fromMillisecondsSinceEpoch(
    num.parse(c[1]).toInt() * 1000
  );
  var lastOnSeconds = int.parse(c[2]);
  var onTodaySeconds = int.parse(c[3]);
  var onForTotalSeconds = int.parse(c[4]);
  var currentMilliWatts = int.parse(c[7]);

  return {
    "state": state,
    "power": currentMilliWatts,
    "onForTime": lastOnSeconds,
    "onForToday": onTodaySeconds,
    "onForTotal": onForTotalSeconds,
    "powerToday": num.parse(c[8]),
    "powerTotal": num.parse(c[9]),
    "lastChange": lastChange.toIso8601String()
  };
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
      return {};
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
  onInvoke(Map params) async {
    var p = path.split("/").take(2).join("/");
    var service = basicEventServices[p];
    await service.invokeAction("GetBinaryState", {}).then((result) {
      var state = int.parse(result["BinaryState"]);
      return service.invokeAction("SetBinaryState", {
        "BinaryState": state == 0 ? 1 : 0
      });
    }).then((l) {
      var state = l["BinaryState"];
      if (state != "Error") {
        try {
          state = int.parse(state);
        } catch (e) {}
      }
      if (state is! int) {
        return null;
      }
      link.val("${p}/BinaryState", state);
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

    var state = params["state"] is String ?
      int.parse(params["state"]) :
      params["state"];

    state = state.toInt();

    var p = path.split("/").take(2).join("/");
    var service = basicEventServices[p];
    return service.invokeAction("SetBinaryState", {
      "BinaryState": state
    }).then((l) {
      var state = l["BinaryState"];
      if (state != "Error") {
        try {
          state = int.parse(state);
        } catch (e) {}
      }
      if (state is! int) {
        return null;
      }
      link.val("${p}/BinaryState", state);
      return {};
    }).catchError((e) {
    });
  }
}

Map<String, Service> basicEventServices = {};
Map<String, Service> deviceEventServices = {};
Map<String, Service> insightServices = {};

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
