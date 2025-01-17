import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:modular_core/modular_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_modular/src/domain/dtos/route_dto.dart';
import 'package:shelf_modular/src/domain/errors/errors.dart';
import 'package:shelf_modular/src/domain/usecases/dispose_bind.dart';
import 'package:shelf_modular/src/domain/usecases/finish_module.dart';
import 'package:shelf_modular/src/domain/usecases/get_arguments.dart';
import 'package:shelf_modular/src/domain/usecases/get_bind.dart';
import 'package:shelf_modular/src/domain/usecases/get_route.dart';
import 'package:shelf_modular/src/domain/usecases/module_ready.dart';
import 'package:shelf_modular/src/domain/usecases/release_scoped_binds.dart';
import 'package:shelf_modular/src/domain/usecases/start_module.dart';
import 'package:shelf_modular/src/shelf_modular_module.dart';
import 'models/module.dart';
import 'utils/handlers.dart';
import 'utils/request_extension.dart';
import 'models/route.dart';

abstract class IModularBase {
  void destroy();
  Future<void> isModuleReady<M extends Module>();
  Handler call({required Module module});
  Future<B> getAsync<B extends Object>({B? defaultValue});

  B get<B extends Object>({
    B? defaultValue,
  });

  bool dispose<B extends Object>();
}

class ModularBase implements IModularBase {
  final DisposeBind disposeBind;
  final GetArguments getArguments;
  final FinishModule finishModule;
  final GetBind getBind;
  final StartModule startModule;
  final GetRoute getRoute;
  final ReleaseScopedBinds releaseScopedBinds;
  final IsModuleReadyImpl isModuleReadyImpl;

  bool _moduleHasBeenStarted = false;

  ModularBase(this.disposeBind, this.finishModule, this.getBind, this.startModule, this.isModuleReadyImpl, this.getRoute, this.getArguments, this.releaseScopedBinds);

  @override
  bool dispose<B extends Object>() => disposeBind<B>().getOrElse((left) => false);

  @override
  B get<B extends Object>({B? defaultValue}) {
    return getBind<B>().getOrElse((left) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw left;
    });
  }

  @override
  Future<B> getAsync<B extends Object>({B? defaultValue}) {
    return getBind<Future<B>>().getOrElse((left) {
      if (defaultValue != null) {
        return Future.value(defaultValue);
      }
      throw left;
    });
  }

  @override
  Future<void> isModuleReady<M extends Module>() => isModuleReadyImpl<M>();

  @override
  void destroy() => finishModule();

  @override
  Handler call({required Module module}) {
    if (!_moduleHasBeenStarted) {
      startModule(module).fold((l) => throw l, (r) => print('${module.runtimeType} started!'));
      _moduleHasBeenStarted = true;
      return _handler;
    } else {
      throw ModuleStartedException('Module ${module.runtimeType} is already started');
    }
  }

  FutureOr<Response> _handler(Request request) async {
    late FutureOr<Response> response;
    try {
      final data = await tryJsonDecode(request);
      final result = await getRoute.call(RouteParmsDTO(url: '/${request.url.toString()}', schema: request.method, arguments: data));
      response = result.fold<FutureOr<Response>>(_routeError, (r) => _routeSuccess(r, request));
    } catch (e, s) {
      response = Response.internalServerError(body: '${e.toString()}/n$s');
    } finally {
      releaseScopedBinds();
      return response;
    }
  }

  FutureOr<Response> _routeSuccess(ModularRoute route, Request request) {
    if (route is Route) {
      final response = applyHandler(
        route.handler!,
        request: request,
        arguments: getArguments().getOrElse((left) => ModularArguments.empty()),
        injector: injector<Injector>(),
      );
      if (response != null) {
        return response;
      } else {
        Response.internalServerError(body: 'Handler not correct');
      }
    }
    return Response.notFound('');
  }

  FutureOr<Response> _routeError(ModularError error) {
    if (error is RouteNotFoundException) {
      return Response.notFound(error.message);
    }

    return Response.internalServerError(body: error.toString());
  }

  Future<Map?> tryJsonDecode(Request request) async {
    if (request.method == 'GET') return null;

    if (!request.isMultipart) {
      try {
        final data = await request.readAsString();
        return jsonDecode(data);
      } on FormatException catch (e) {
        if (e.message == 'Unexpected extension byte') {
        } else if (e.message == 'Missing expected digit') {}
        return null;
      }
    } else {
      await for (final part in request.parts) {
        final params = <String, dynamic>{};
        var header = HeaderValue.parse(request.headers['content-type']!);
        if (part.headers.containsKey('content-disposition')) {
          header = HeaderValue.parse(part.headers['content-disposition']!);
          final key = header.parameters['name'];
          if (key == null) {
            continue;
          }
          if (!header.parameters.containsKey('filename')) {
            final value = await utf8.decodeStream(part);
            params[key] = value;
          } else {
            final file = File(header.parameters['filename']!);
            final fileSink = file.openWrite();
            await part.pipe(fileSink);
            await fileSink.close();
            params[key] = file;
          }
        }
        return params;
      }
    }
  }
}
