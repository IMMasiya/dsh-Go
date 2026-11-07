// The agent preset and permission picked on the new-chat screen before a
// session exists. Like the pending model (models_state.dart), they belong to
// one host/connection lifetime and are applied to the session right after it
// is created, before its first prompt.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models_state.dart' show modelSelectionScopeProvider;

/// Presets a new chat never offers: the companion room's own preset is set up
/// by the room, not chosen for an ordinary conversation.
const hiddenNewChatPresets = {'dsh-go-companion-full'};

/// What the new-chat screen asked for. Null fields keep the Host's default.
class NewChatModes {
  const NewChatModes({this.preset, this.permission});

  /// Agent preset id (`agentPresets/select`).
  final String? preset;

  /// Permission preset value (`/permission`).
  final String? permission;

  bool get isEmpty => preset == null && permission == null;

  NewChatModes withPreset(String? value) => NewChatModes(preset: value, permission: permission);
  NewChatModes withPermission(String? value) => NewChatModes(preset: preset, permission: value);

  @override
  bool operator ==(Object other) => other is NewChatModes && other.preset == preset && other.permission == permission;

  @override
  int get hashCode => Object.hash(preset, permission);
}

class PendingNewChatModes extends Notifier<NewChatModes> {
  @override
  NewChatModes build() {
    // A choice made for one host must not reach a host selected later, nor a
    // new connection generation of the same host.
    ref.watch(modelSelectionScopeProvider);
    return const NewChatModes();
  }

  /// Picks [preset]; null (or the Host default) keeps the default.
  void selectPreset(String? preset) => state = state.withPreset(preset);

  /// Picks [permission]; null (or the effective default) keeps the default.
  void selectPermission(String? permission) => state = state.withPermission(permission);

  void clear() => state = const NewChatModes();
}

final pendingNewChatModesProvider = NotifierProvider<PendingNewChatModes, NewChatModes>(PendingNewChatModes.new);
