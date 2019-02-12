// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:mirrors';

import 'package:vm_service_lib/vm_service_lib.dart';

import 'vm_service_rpcs.dart';

/// A dispatch mechanism to the VM service APIs.
class ServiceDispatcher {
  ServiceDispatcher(String host, int port) {
    service = Service(host, port, _streamNotify);
    _this = reflect(service);
    _class = _this.type;
    _input.stream.listen(_handle);
  }

  Service service;
  InstanceMirror _this;
  ClassMirror _class;

  final _input = StreamController<Map<String, Object>>();
  final _output = StreamController<Map<String, Object>>();

  StreamSink<Map<String, Object>> get input => _input.sink;
  Stream<Map<String, Object>> get output => _output.stream;

  Future get ready => service.ready;

  void _streamNotify(String streamId, Event event) {
    _output.add({
      'method': 'streamNotify',
      'params': {'streamId': streamId, 'event': event.toJson()}
    });
  }

  Invocation _invocation(Symbol method, Map<String, Object> parameters) {
    var member = _class.instanceMembers[method];
    var positionals = [];
    var named = <Symbol, Object>{};

    var params = parameters.map((name, obj) => MapEntry(Symbol(name), obj));

    for (var p in member.parameters) {
      var type = p.type;
      var arg = params[p.simpleName];
      if (type is ClassMirror && type.isEnum) {
        // TODO(vsm): Cache this for efficiency?
        var values = type.getField(#values).reflectee as List;
        for (var value in values) {
          print('TEST: $value and $arg');
          if ('$value'.endsWith('.$arg')) {
            arg = value;
            break;
          }
        }
      }
      if (!p.isNamed) {
        assert(!p.isOptional);
        positionals.add(arg);
      } else {
        named[p.simpleName] = arg;
      }
    }
    return Invocation.method(method, positionals, named);
  }

  Future<dynamic> _dispatch(Map<String, Object> request) async {
    try {
      var method = Symbol(request['method'] as String);
      var params =
          request['params'] as Map<String, Object> ?? <String, Object>{};
      var invocation = _invocation(method, params);
      return _this.delegate(invocation);
    } catch (e, st) {
      var error = e is RpcError ? e : RpcError.unknown('$e: $st');
      throw error;
    }
  }

  void _handle(Map<String, Object> request) async {
    var id = request['id'];
    try {
      var response = await _dispatch(request);
      var result = response.toJson();
      _output.add({'id': id, 'result': result});
    } on RpcError catch (error) {
      _output.add({'id': id, 'error': error.toJson()});
    }
  }
}
