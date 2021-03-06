// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@JS()
library hot_reload_client;

import 'dart:async';
import 'dart:html';

import 'package:js/js.dart';
import 'package:js/js_util.dart';
import 'package:sse/client/sse_client.dart';

import 'module.dart';
import 'reloading_manager.dart';

// GENERATE:
// dart2js lib/src/serve/reload_client/hot_restart/client.dart -o lib/src/serve/reload_client/hot_restart_client.js -m
Future<void> main() async {
  var currentDigests = await _getDigests();

  var manager = ReloadingManager(
      _reloadModule,
      _moduleLibraries,
      _reloadPage,
      (module) => dartLoader.moduleParentsGraph.get(module)?.cast(),
      () => keys(dartLoader.moduleParentsGraph));

  var client = SseClient(r'/$sseHandler');
  client.stream.listen((_) async {
    var newDigests = await _getDigests();
    var modulesToLoad = <String>[];
    for (var module in newDigests.keys) {
      if (!currentDigests.containsKey(module) ||
          currentDigests[module] != newDigests[module]) {
        modulesToLoad.add(module.replaceFirst('.js', ''));
      }
    }
    currentDigests = newDigests;
    if (modulesToLoad.isNotEmpty) {
      manager.updateGraph();
      await manager.reload(modulesToLoad);
    }
  });
}

@JS(r'$dartLoader')
external DartLoader get dartLoader;

List<K> keys<K, V>(JsMap<K, V> map) {
  return List.from(_jsArrayFrom(map.keys()));
}

Future<Map<String, String>> _getDigests() async {
  var request = await HttpRequest.request(dartLoader.appDigests,
      responseType: 'json', method: 'GET');
  return (request.response as Map).cast<String, String>();
}

@JS('Array.from')
external List _jsArrayFrom(Object any);

@JS('Object.keys')
external List _jsObjectKeys(Object any);

@JS('Object.values')
external List _jsObjectValues(Object any);

Module _moduleLibraries(String moduleId) {
  var moduleObj = dartLoader.getModuleLibraries(moduleId);
  if (moduleObj == null) {
    throw HotReloadFailedException("Failed to get module '$moduleId'. "
        "This error might appear if such module doesn't exist or isn't already loaded");
  }
  var moduleKeys = List<String>.from(_jsObjectKeys(moduleObj));
  var moduleValues =
      List<HotReloadableLibrary>.from(_jsObjectValues(moduleObj));
  var moduleLibraries = moduleValues.map((x) => LibraryWrapper(x));
  return Module(Map.fromIterables(moduleKeys, moduleLibraries));
}

Future<Module> _reloadModule(String moduleId) {
  var completer = Completer<Module>();
  var stackTrace = StackTrace.current;
  dartLoader.forceLoadModule(moduleId, allowInterop(() {
    completer.complete(_moduleLibraries(moduleId));
  }),
      allowInterop((e) => completer.completeError(
          HotReloadFailedException(e.message), stackTrace)));
  return completer.future;
}

void _reloadPage() {
  window.location.reload();
}

@anonymous
@JS()
class DartLoader {
  @JS()
  external String get appDigests;

  @JS()
  external JsMap<String, List<String>> get moduleParentsGraph;

  @JS()
  external void forceLoadModule(String moduleId, void Function() callback,
      void Function(JsError e) onError);

  @JS()
  external Object getModuleLibraries(String moduleId);
}

@anonymous
@JS()
abstract class HotReloadableLibrary {
  /// Implement this function to handle update of child modules.
  ///
  /// May return nullable bool. To indicate that reload of child completes
  /// successfully return true. To indicate that hot-reload is undoable for this
  /// child return false - this will lead to full page reload. If null returned,
  /// reloading will be propagated to current module itself.
  ///
  /// The name of the child will be provided in [childId]. New version of child
  /// module object will be provided in [child].
  /// If any state was saved from previous version, it will be passed to [data].
  ///
  /// This function will be called on old version of module current after child
  /// reloading.
  @JS()
  external bool hot$onChildUpdate(String childId, HotReloadableLibrary child,
      [Object data]);

  /// Implement this function with any code to release resources before destroy.
  ///
  /// Any object returned from this function will be passed to update hooks. Use
  /// it to save any state you need to be preserved between hot reloadings.
  /// Try do not use any custom types here, as it might prevent their code from
  /// reloading. Better serialise to JSON or plain types.
  ///
  /// This function will be called on old version of module before unloading.
  @JS()
  external Object hot$onDestroy();

  /// Implement this function to handle update of the module itself.
  ///
  /// May return nullable bool. To indicate that reload completes successfully
  /// return true. To indicate that hot-reload is undoable return false - this
  /// will lead to full page reload. If null returned, reloading will be
  /// propagated to parent.
  ///
  /// If any state was saved from previous version, it will be passed to [data].
  ///
  /// This function will be called on new version of module after reloading.
  @JS()
  external bool hot$onSelfUpdate([Object data]);
}

@JS('Error')
abstract class JsError {
  @JS()
  external String get message;

  @JS()
  external String get stack;
}

@JS('Map')
abstract class JsMap<K, V> {
  @JS()
  external V get(K key);

  @JS()
  external Object keys();
}

class LibraryWrapper implements Library {
  final HotReloadableLibrary _internal;

  LibraryWrapper(this._internal);

  @override
  bool onChildUpdate(String childId, Library child, [Object data]) {
    if (_internal != null && hasProperty(_internal, r'hot$onChildUpdate')) {
      return _internal.hot$onChildUpdate(
          childId, (child as LibraryWrapper)._internal, data);
    }
    // ignore: avoid_returning_null
    return null;
  }

  @override
  Object onDestroy() {
    if (_internal != null && hasProperty(_internal, r'hot$onDestroy')) {
      return _internal.hot$onDestroy();
    }
    return null;
  }

  @override
  bool onSelfUpdate([Object data]) {
    if (_internal != null && hasProperty(_internal, r'hot$onSelfUpdate')) {
      return _internal.hot$onSelfUpdate(data);
    }
    // ignore: avoid_returning_null
    return null;
  }
}
