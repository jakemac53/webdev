// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:source_maps/source_maps.dart' as sm;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

import 'package:vm_service_lib/vm_service_lib.dart';

typedef StreamNotifier = void Function(String, Event);

/// This is based on the Dart VM Service Protocol:
/// https://github.com/dart-lang/sdk/blob/master/runtime/vm/service/service.md
///
/// Version 3.13
class Service {
  Future<Breakpoint> _addBreakpoint(
      String isolateId, ScriptRef script, int line,
      {int column}) async {
    var isolate = _getIsolate(isolateId);
    var jsId = _dartIdToJsId[script.id];
    var locations = _jsIdToLocationData[jsId];
    var locationData = locations.dartLocations[script.uri];

    for (var location in locationData) {
      // Match first line hit for now.
      if (location.dartLine >= line) {
        WipResponse result;
        try {
          result = await _cdp.debugger
              .sendCommand('Debugger.setBreakpoint', params: {
            'location': {
              'scriptId': jsId,
              'lineNumber': location.jsLine - 1,
            }
          });
        } catch (e) {
          throw RpcError(102)..data.details = '$e';
        }

        var jsBreakpointId = result.result['breakpointId'] as String;
        // TODO(vsm):
        // (1) Validate that the breakpoint was resolved.
        // (2) Update the location to the actual location (in result.result).

        var breakpoint = _createBreakpoint()
          ..resolved = true
          ..location = (SourceLocation()
            ..script = script
            ..tokenPos = location.dartTokenPos);

        _jsBreakpointIdToDartId[jsBreakpointId] = breakpoint.id;
        _dartBreakpointIdToJsId[breakpoint.id] = jsBreakpointId;

        _streamNotify(
            'Debug',
            Event()
              ..kind = EventKind.kBreakpointAdded
              ..isolate = (IsolateRef()
                ..id = isolate.id
                ..number = isolate.number
                ..name = isolate.name)
              ..breakpoint = breakpoint);
        return breakpoint;
      }
    }
    throw RpcError(102)..data.details = 'Unable to match a dart line location';
  }

  Future<Breakpoint> addBreakpoint(String isolateId, String scriptId, int line,
      {int column}) async {
    var script = _getScriptById(isolateId, scriptId);
    return _addBreakpoint(isolateId, script, line, column: column);
  }

  ScriptRef _getScriptById(String isolateId, String scriptId) {
    var scripts = _getScripts(isolateId);
    for (var script in scripts) {
      if (script.id == scriptId) {
        return script;
      }
    }
    return null;
  }

  Future<Breakpoint> addBreakpointWithScriptUri(
      String isolateId, String scriptUri, int line,
      {int column}) async {
    var isolate = _getIsolate(isolateId);
    scriptUri = _convertToBrowserUrl(isolate, scriptUri) ?? scriptUri;
    var script = _dartUrlToScript[scriptUri];
    return _addBreakpoint(
        isolateId,
        ScriptRef()
          ..id = script.id
          ..type = '@Script',
        line,
        column: column);
  }

  String _convertToBrowserUrl(Isolate isolate, String fileUrl) {
    String suffix;
    var parts = p.split(fileUrl);
    // TODO(vsm): How do we robustly compute the package structure we're
    // currently in?  This can break if 'lib' or 'web' appear within the
    // package.
    for (var i = parts.length - 1; i > 0; --i) {
      var part = parts[i];
      if (part == 'lib') {
        // var package = parts[i - 1];
        suffix = p.joinAll(parts.sublist(i +
            1)); // p.join('packages', package, p.joinAll(parts.sublist(i + 1)));
        break;
      } else if (part == 'web') {
        suffix = p.joinAll(parts.sublist(i + 1));
      }
    }
    if (suffix == null) return null;

    var libraries = isolate.libraries;
    var lib = libraries.firstWhere((lib) => lib.uri.endsWith(suffix),
        orElse: () => null);
    return lib?.uri;
  }

  Future<Breakpoint> addBreakpointAtEntry(
      String isolateId, String functionId) async {
    throw UnimplementedError('addBreakpointAtEntry');
  }

  Future<Object> /*InstanceRef|ErrorRef|Sentinel*/ invoke(String isolateId,
      String targetId, String selector, List<String> argumentIds) async {
    throw UnimplementedError('invoke');
  }

  Future<Object> /*InstanceRef|ErrorRef|Sentinel*/ evaluate(
      String isolateId, String targetId, String expression,
      {Map<String, String> scope}) async {
    throw UnimplementedError('evaluate');
  }

  Future<Object> /*InstanceRef|ErrorRef|Sentinel*/ evaluateInFrame(
      String isolateId, int frameIndex, String expression,
      {Map<String, String> scope}) async {
    throw UnimplementedError('evaluateInFrame');
  }

  Future<FlagList> getFlagList() async {
    throw UnimplementedError('getFlagList');
  }

  Isolate _getIsolate(String isolateId) =>
      _realIsolatesById[isolateId]; // ?? Sentinel();

  Future<Isolate> /*Isolate|Sentinel*/ getIsolate(String isolateId) async =>
      _getIsolate(isolateId);

  List<ScriptRef> _getScripts(String isolateId) {
    var isolate = _getIsolate(isolateId);
    var libraries = _realLibrariesByIsolateId[isolate.id];
    var scripts = <ScriptRef>[];
    for (var lib in libraries) {
      scripts.addAll(lib.scripts);
    }
    return scripts;
  }

  Future<ScriptList> getScripts(String isolateId) async {
    var scripts = _getScripts(isolateId);
    return ScriptList()..scripts = scripts;
  }

  Future<Object> /*Obj|Sentinel*/ getObject(String isolateId, String objectId,
      {int offset, int count}) async {
    // TODO(vsm): Qualify to isolateId.
    return _objectMap[objectId];
  }

  Future<Stack> getStack(String isolateId) async {
    return _pausedStack;
  }

  Future<SourceReport> getSourceReport(
      String isolateId, List<SourceReportKind> reports,
      {String scriptId,
      int tokenPos,
      int endTokenPos,
      bool forceCompile}) async {
    throw UnimplementedError('getSourceReport');
  }

  Future<Version> getVersion() async {
    throw UnimplementedError('getVersion');
  }

  Future<VM> getVM() async {
    return _vm;
  }

  Future<Success> pause(String isolateId) async {
    // TODO(vsm): Support multiple isolates.
    if (_vm.isolates.first.id == isolateId) {
      await _cdp.debugger.pause();
    }
    return Success();
  }

  Future<Success> kill(String isolateId) async {
    throw UnimplementedError('kill');
  }

  Future<ReloadReport> reloadSources(String isolateId,
      {bool force, bool pause, String rootLibUri, String packagesUri}) async {
    throw UnimplementedError('reloadSources');
  }

  Future<Success> removeBreakpoint(
      String isolateId, String breakpointId) async {
    throw UnimplementedError('removeBreakpoint');
  }

  Future<Success> resume(String isolateId,
      {String step, int frameIndex}) async {
    // TODO(vsm): Support multiple isolates.
    if (_vm.isolates.first.id == isolateId) {
      if (step == null) {
        await _cdp.debugger.resume();
      } else {
        switch (step) {
          case StepOption.kInto:
            await _cdp.debugger.stepInto();
            break;
          case StepOption.kOut:
            await _cdp.debugger.stepOut();
            break;
          case StepOption.kOver:
            await _cdp.debugger.stepOver();
            break;
          default:
          // TODO(vsm): ...
        }
      }
    }
    return Success();
  }

  Future<Success> setExceptionPauseMode(String isolateId, String mode) async {
    PauseState chromeMode;
    switch (mode) {
      case ExceptionPauseMode.kAll:
        chromeMode = PauseState.all;
        break;
      case ExceptionPauseMode.kUnhandled:
        chromeMode = PauseState.uncaught;
        break;
      case ExceptionPauseMode.kNone:
        chromeMode = PauseState.none;
        break;
    }
    await _cdp.debugger.setPauseOnExceptions(chromeMode);
    return Success();
  }

  Future<Success> setFlag(String name, String value) async {
    throw UnimplementedError('setFlag');
  }

  Future<Success> setLibraryDebuggable(
      String isolateId, String libraryId, bool isDebuggable) async {
    // TODO(vsm): Enable / disable debugging on this library.  We'll need to
    // figure out how to map to this granularity on a JS Script.
    return Success();
  }

  Future<Success> setName(String isolateId, String name) async {
    var isolate =
        _vm.isolates.firstWhere((i) => i.id == isolateId, orElse: () => null);
    if (isolate != null) isolate.name = name;
    _realIsolatesById[isolateId]?.name = name;
    return Success();
  }

  Future<Success> setVMName(String name) async {
    throw UnimplementedError();
  }

  Future<Success> streamCancel(String streamId) async {
    if (_subscribedStreams.contains(streamId)) {
      _subscribedStreams.remove(streamId);
      return Success();
    } else {
      throw RpcError(104);
    }
  }

  Future<Success> streamListen(String streamId) async {
    if (!_subscribedStreams.contains(streamId)) {
      _subscribedStreams.add(streamId);
      return Success();
    } else {
      throw RpcError(103);
    }
  }

  Service(String host, int port, this._streamNotifier)
      : _chrome = ChromeConnection(host, port),
        _initialized = Completer() {
    _initialize();
  }

  int _objectId = 0;
  String _genId([String prefix = 'object']) => '$prefix/${_objectId++}';

  Future<String> _fetch(String uri) async {
    try {
      if (uri.startsWith('file://')) {
        uri = uri.substring('file://'.length);
        return await File(uri).readAsString();
      } else {
        var request = await new HttpClient().postUrl(Uri.parse(uri));
        request.persistentConnection = false; // Use non-persistent connection.
        var response = await request.close();
        return response.statusCode != HttpStatus.notFound
            ? response.transform(utf8.decoder).join()
            : null;
      }
    } catch (e) {
      return null;
    }
  }

  void _initialize() async {
    // TODO(vsm): For now, we find the first user tab and assume that's the one
    // to debug.  We also assume this is the one, single Dart isolate for now.

    // Find a Chrome 'Isolate'.
    final tab = await _chrome.getTab((ChromeTab tab) {
      return !tab.isBackgroundPage &&
          !tab.isChromeExtension &&
          !tab.url.startsWith('chrome-devtools://');
    });
    _cdp = await tab.connect();

    // Initialize the Dart 'VM'.
    var isolate = _createIsolate()
      ..name = '${tab.url}:main()'
      ..runnable = true
      ..breakpoints = []
      ..libraries = [];
    var isolateRef = IsolateRef()
      ..id = isolate.id
      ..name = isolate.name
      ..number = isolate.number
      ..type = '@Isolate';
    isolate.pauseEvent = (Event()
      ..kind = EventKind.kResume
      ..isolate = isolateRef);
    _vm = VM()
      ..isolates = [isolateRef]
      // TODO(vsm): This should be the DDC version, not the VM one.
      ..version = Platform.version;

    _cdp.runtime.enable();
    await _cdp.runtime
        .evaluate('console.log("Dart Web Debugger Proxy Running")');
    _cdp.runtime.onConsoleAPICalled.listen((e) {
      var args = e.params['args'] as List;
      var item = args[0] as Map;
      var value = '${item["value"]}\n';
      _streamNotify(
          'Stdout',
          Event()
            ..kind = EventKind.kWriteEvent
            ..isolate = isolateRef
            ..bytes = base64.encode(value.codeUnits));
    });

    // Parse and map script in the browser back to Dart libraries.
    _cdp.debugger.enable();
    _cdp.debugger.onScriptParsed.listen((e) async {
      _processJsScript(e.script);
    });
    _cdp.debugger.onPaused.listen((e) async {
      var params = e.params;
      var event = Event()..isolate = isolateRef;
      var breakpoints = params['hitBreakpoints'] as List;
      if (breakpoints.isNotEmpty) {
        // Use the first one for now.
        var jsBreakpoint = breakpoints.first;
        var dartBreakpoint = _jsBreakpointIdToDartId[jsBreakpoint];
        var breakpoint = _objectMap[dartBreakpoint] as Breakpoint;
        event
          ..kind = EventKind.kPauseBreakpoint
          ..breakpoint = breakpoint
          ..pauseBreakpoints = [breakpoint];
      } else if (e.reason == 'exception' || e.reason == 'assert') {
        event.kind = EventKind.kPauseException;
      } else {
        event.kind = EventKind.kPauseInterrupted;
      }

      // var jsFrames = e.getCallFrames().toList();
      var jsFrames = (e.params['callFrames'] as List)
          .map((frame) => new WipCallFrame(frame as Map<String, dynamic>))
          .toList();
      var dartFrames = <Frame>[];
      var index = 0;
      for (var jsFrame in jsFrames) {
        var dartFrame = _mapFrame(jsFrame);
        if (dartFrame != null) {
          dartFrames.add(dartFrame..index = index++);
        }
      }
      _pausedStack = Stack()
        ..frames = dartFrames
        ..messages = [];
      _streamNotify('Debug', event);
    });
    _cdp.debugger.onResumed.listen((e) async {
      _pausedStack = null;
      _streamNotify(
          'Debug',
          Event()
            ..kind = EventKind.kResume
            ..isolate = isolateRef);
    });

    // TODO(vsm): Wait properly for page to load?
    Future<void>.delayed(const Duration(milliseconds: 1000), () {
      // We delay a small amount in order to allow the script information to
      // be populated as events.

      _initialized.complete();
    });
  }

  void _streamNotify(String streamId, Event e) {
    if (_subscribedStreams.contains(streamId)) _streamNotifier(streamId, e);
  }

  Frame _mapFrame(WipCallFrame jsFrame) {
    var jsLocation = jsFrame.location;
    var jsId = jsLocation.scriptId;
    print(jsFrame);
    print(jsId);
    var jsLine = jsLocation.lineNumber;
    print(jsLine);
    // var jsColumn = jsLocation.columnNumber;
    var locationData = _jsIdToLocationData[jsId];
    var locations = locationData.dartLocations;
    for (var dartUrl in locations.keys) {
      for (var location in locations[dartUrl]) {
        if (location.jsLine > jsLine) {
          // TODO(vsm): Look for best match.
          print("Mapped frame to $dartUrl:${location.dartLine}");
          var script = _dartUrlToScript[dartUrl];
          if (script != null) {
            return Frame()
              ..code = (CodeRef()
                ..id = 'dummy'
                ..name = jsFrame.functionName
                ..kind = CodeKind.kDart)
              ..location = (SourceLocation()
                ..tokenPos = location.dartTokenPos
                ..script = script != null
                    ? (new ScriptRef()
                      ..id = script.id
                      ..type = '@Script'
                      ..uri = script.uri)
                    : null)
              ..kind = FrameKind.kRegular;
          }
        }
      }
    }
    print('Failed');
    return null;
  }

  // Chrome Debug Protocol Connection.
  final ChromeConnection _chrome;
  WipConnection _cdp;

  // Callback to dispatch out-of-band Event objects.  See [streamListen] and
  // [streamCancel] below.
  final StreamNotifier _streamNotifier;
  final Set<String> _subscribedStreams = Set();

  // Indicater that this [Service] is initialized and ready.
  final Completer _initialized;
  Future get ready => _initialized.future;

  VM _vm;
  final _realIsolatesById = <String, Isolate>{};
  final _realLibrariesByIsolateId = <String, List<Library>>{};
  final _realScriptByLibraryId = <String, List<Script>>{};

  T _create<T extends Obj>(T Function() cons) {
    var id = _genId('$T');
    var obj = cons()..id = id;
    _objectMap[id] = obj;
    return obj;
  }

  Library _createLibrary(String isolateId) {
    var lib = _create(() => Library());
    _realLibrariesByIsolateId.putIfAbsent(isolateId, () => []).add(lib);
    return lib;
  }

  Script _createScript(String libraryId) {
    var script = _create(() => Script());
    _realScriptByLibraryId.putIfAbsent(libraryId, () => []).add(script);
    return script;
  }

  int _breakpointCounter = 0;
  Breakpoint _createBreakpoint() =>
      _create(() => Breakpoint()..breakpointNumber = ++_breakpointCounter);

  Isolate _createIsolate() {
    var id = _genId('Isolate');
    var isolate = Isolate()..id = id;
    _realIsolatesById[isolate.id] = isolate;
    return isolate;
  }

  void _processJsScript(WipScript jsScript) async {
    // TODO(vsm): Isolates and libraries should be introspected from the browser.
    var isolate = _getIsolate(_vm.isolates.first.id) as Isolate;
    var libraries = isolate.libraries;

    var sourceMapUrl = jsScript.sourceMapURL;
    if (sourceMapUrl != null && sourceMapUrl.isNotEmpty) {
      sourceMapUrl = p.join(p.dirname(jsScript.url), sourceMapUrl);
      var sourceMapContents = await _fetch(sourceMapUrl);
      if (sourceMapContents != null) {
        // This happens to be a [SingleMapping] today in DDC.
        var mapping = sm.parse(sourceMapContents);
        if (mapping is sm.SingleMapping) {
          var jsId = jsScript.scriptId;
          var jsUrl = jsScript.url;

          _jsUrlToJsId[jsUrl] = jsId;
          var locationData = DartLocationData(jsUrl, jsId, mapping);
          _jsIdToLocationData[jsId] = locationData;

          for (var src in mapping.urls) {
            // TODO(vsm): Support part files.
            var dartUrl = p.join(p.dirname(jsUrl), src);
            // TODO(vsm): Record this properly.
            var dartSource = await _fetch(dartUrl);
            if (dartSource == null) continue;

            var library = _createLibrary(isolate.id)
              ..uri = dartUrl
              ..name = p.basenameWithoutExtension(dartUrl)
              ..scripts = <ScriptRef>[];
            var dartScript = _createScript(library.id)
              ..uri = dartUrl
              ..tokenPosTable = locationData.dartUrlToTokenPosTable[dartUrl]
              ..source = dartSource;
            _dartIdToJsId[dartScript.id] = jsId;
            _dartUrlToScript[dartUrl] = dartScript;
            var libraryRef = LibraryRef()
              ..id = library.id
              ..name = library.name
              ..type = '@Library'
              ..uri = library.uri;
            var dartScriptRef = ScriptRef()
              ..id = dartScript.id
              ..type = '@Script'
              ..uri = dartScript.uri;
            library.scripts.add(dartScriptRef);
            // TODO(vsm): Need a robust way to query for the root library.
            if (libraries.isEmpty) isolate.rootLib = libraryRef;
            libraries.add(libraryRef);
          }
        } else {
          throw UnsupportedError('Only SingleMapping is supported.');
        }
        _mappings.add(mapping as sm.SingleMapping);
      }
    }
  }

  // TODO(vsm): Make these per isolate?

  // Object Map: ID => Object.
  // TODO(vsm): Make this per isolate.
  final Map<String, Obj> _objectMap = {};

  // JS Script ID to ..
  final Map<String, Set<Library>> _jsIdToLibraries = {};
  final Map<String, DartLocationData> _jsIdToLocationData = {};

  final Map<String, Script> _dartUrlToScript = {};

  final Map<String, String> _dartIdToJsId = {};
  final Map<String, String> _jsUrlToJsId = {};
  final List<sm.SingleMapping> _mappings = [];

  // Breakpoints
  final Map<String, String> _jsBreakpointIdToDartId = {};
  final Map<String, String> _dartBreakpointIdToJsId = {};
  Stack _pausedStack = null;
}

class RpcErrorData {
  RpcErrorData(this.details);

  String details;
}

class RpcError implements Exception {
  RpcError._(this.code, this.message, String details)
      : data = RpcErrorData(details);

  RpcError(int code) : this._(code, _errorCodes[code][0], _errorCodes[code][1]);

  RpcError.unknown([String message]) : this._(100, 'Unexpected error', message);

  int code;

  String message;

  RpcErrorData data;

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        'data': {
          'type': 'RpcErrorData',
          'details': data.details,
        },
        'type': 'RpcError',
      };
}

// Dart Location data corresponding to a single JS Script.
class DartLocationData {
  DartLocationData(String jsUrl, String jsScriptId, this.mapping) {
    var tokenPos = 100;
    var currentLine = -1;

    var parent = p.dirname(jsUrl);

    // TODO(vsm): Does this need to be sorted?
    List<List<int>> tokenPosTable;
    List<DartLocationMapping> dartLocationList;
    List<int> current = null;
    for (var lineEntry in mapping.lines) {
      for (var entry in lineEntry.entries) {
        var index = entry.sourceUrlId;
        var dartUrl = p.join(parent, mapping.urls[index]);
        tokenPosTable = dartUrlToTokenPosTable.putIfAbsent(dartUrl, () => []);
        dartLocationList = dartLocations.putIfAbsent(dartUrl, () => []);
        var dartLine = entry.sourceLine;
        var dartColumn = entry.sourceColumn;

        // TODO(vsm): This is broken - assumes Dart is laid out contiguously
        // in JS.
        if (dartLine != currentLine) {
          currentLine = dartLine;
          current = [dartLine];
          tokenPosTable.add(current);
        }
        current.addAll([tokenPos, dartColumn]);
        dartLocationList.add(DartLocationMapping(jsScriptId, lineEntry.line,
            entry.column, dartUrl, dartLine, dartColumn, tokenPos));
        tokenPos += 1;
      }
    }
  }

  final sm.SingleMapping mapping;
  // Keyed by Dart URL.
  final Map<String, List<List<int>>> dartUrlToTokenPosTable = {};
  // This should be sorted by JS line #s.
  final Map<String, List<DartLocationMapping>> dartLocations = {};
}

class DartLocationMapping {
  DartLocationMapping(this.jsScriptId, this.jsLine, this.jsColumn, this.dartUrl,
      this.dartLine, this.dartColumn, this.dartTokenPos);

  final String jsScriptId;
  final int jsLine;
  final int jsColumn;
  final String dartUrl;
  final int dartLine;
  final int dartColumn;
  final int dartTokenPos;
}

Map<int, List<String>> _errorCodes = {
  100: [
    'Feature is disabled',
    'The operation is unable to complete because a feature is disabled'
  ],
  101: [
    'VM must be paused',
    'This operation is only valid when the VM is paused'
  ],
  102: [
    'Cannot add breakpoint',
    'The VM is unable to add a breakpoint at the specified line or function'
  ],
  103: [
    'Stream already subscribed',
    'The client is already subscribed to the specified streamId'
  ],
  104: [
    'Stream not subscribed',
    'The client is not subscribed to the specified streamId'
  ],
  105: [
    'Isolate must be runnable',
    'This operation cannot happen until the isolate is runnable'
  ],
  106: [
    'Isolate must be paused',
    'This operation is only valid when the isolate is paused'
  ],
  107: ['Cannot resume execution', 'The isolate could not be resumed'],
  108: [
    'Isolate is reloading',
    'he isolate is currently processing another reload request'
  ],
  109: [
    'Isolate cannot be reloaded',
    'The isolate has an unhandled exception and can no longer be reloaded'
  ],
  110: [
    'Isolate must have reloaded',
    'Failed to find differences in last hot reload request'
  ],
  111: [
    'Service already registered',
    'Service with such name has already been registered by this client'
  ],
  112: [
    'Service disappeared',
    'Failed to fulfill service request, likely service handler is no longer available'
  ],
  113: ['Expression compilation error', 'Request to compile expression failed'],
};
