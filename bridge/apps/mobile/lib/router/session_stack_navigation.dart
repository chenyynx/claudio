import 'dart:collection';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';

import 'app_router.dart';

@immutable
class SessionRouteIdentity {
  final String sessionId;
  final String provider;

  const SessionRouteIdentity({required this.sessionId, required this.provider});

  bool matches({required String sessionId, required String provider}) {
    return this.sessionId == sessionId && this.provider == provider;
  }
}

class SessionRouteRegistry {
  SessionRouteRegistry._();

  static final SessionRouteRegistry instance = SessionRouteRegistry._();

  final Map<Object, ({Object owner, SessionRouteIdentity identity})> _routes =
      HashMap.identity();

  void update({
    required Object routeIdentity,
    required Object owner,
    required String sessionId,
    required String provider,
  }) {
    _routes[routeIdentity] = (
      owner: owner,
      identity: SessionRouteIdentity(sessionId: sessionId, provider: provider),
    );
  }

  void remove({required Object routeIdentity, required Object owner}) {
    final registered = _routes[routeIdentity];
    if (registered != null && identical(registered.owner, owner)) {
      _routes.remove(routeIdentity);
    }
  }

  SessionRouteIdentity? identityFor(Object routeIdentity) {
    return _routes[routeIdentity]?.identity;
  }

  @visibleForTesting
  void clear() {
    _routes.clear();
  }
}

class SessionStackNavigation {
  const SessionStackNavigation._();

  static bool revealStackedSession(
    StackRouter router, {
    required String sessionId,
    required String provider,
  }) {
    final rootRouter = router.root;
    final targetIndex = rootRouter.stack.indexWhere(
      (page) => matchesDestination(
        routeIdentity: page,
        routeName: page.routeData.name,
        arguments: page.routeData.args,
        sessionId: sessionId,
        provider: provider,
      ),
    );
    if (targetIndex == -1 || rootRouter.navigatorKey.currentState == null) {
      return false;
    }

    final targetPage = rootRouter.stack[targetIndex];
    rootRouter.popUntil((route) => identical(route.settings, targetPage));
    return true;
  }

  @visibleForTesting
  static bool matchesDestination({
    required Object routeIdentity,
    required String routeName,
    required Object? arguments,
    required String sessionId,
    required String provider,
  }) {
    final liveIdentity = SessionRouteRegistry.instance.identityFor(
      routeIdentity,
    );
    if (liveIdentity != null) {
      return liveIdentity.matches(sessionId: sessionId, provider: provider);
    }
    if (routeName == ClaudeSessionRoute.name &&
        provider == 'claude' &&
        arguments is ClaudeSessionRouteArgs) {
      return arguments.sessionId == sessionId;
    }
    if (routeName == CodexSessionRoute.name &&
        provider == 'codex' &&
        arguments is CodexSessionRouteArgs) {
      return arguments.sessionId == sessionId;
    }
    return false;
  }
}
