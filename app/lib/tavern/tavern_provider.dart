// The app's one [Tavern]: the engine (packages/dsh_tavern) opened on
// `<app support>/tavern`. It opens asynchronously, so the screens get a
// [DeferredTavern] that queues calls until it is ready. It follows 酒馆设置's
// channel and reads that channel's key (the app's DeepSeek key for the
// built-in one) on every call; the engine never stores a key. Tests swap in
// the preview stand-in (tavern_preview.dart).

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../state/settings_state.dart';
import 'deferred_tavern.dart';
import 'tavern_channels.dart';
import 'tavern_script_host.dart';
import 'tavern_settings.dart';

final tavernProvider = Provider<Tavern>((ref) {
  final tavern = DeferredTavern(() async {
    final support = await getApplicationSupportDirectory();
    return openTavern('${support.path}/tavern');
  }());
  ref.onDispose(tavern.close);
  final keys = ref.read(tavernChannelKeysProvider);
  void configure(TavernSettings settings) {
    final channel = settings.activeChannel;
    tavern.configure(
      TavernModelConfig(
        apiKey: () async {
          final key = (channel == null ? ref.read(settingsProvider).apiKey : await keys.read(channel.id))?.trim();
          return key == null || key.isEmpty ? null : key;
        },
        baseUrl: channel?.baseUrl ?? tavernDeepSeekBaseUrl,
        model: settings.activeModel,
        deepseek: settings.deepseekApi,
        thinking: settings.thinking,
      ),
    );
  }

  configure(ref.read(tavernSettingsProvider));
  ref.listen(tavernSettingsProvider, (_, next) => configure(next));
  return tavern;
});

/// The app's host for card scripts, one per tavern: what the engine delivers
/// to a canvas page's script context goes to that page.
final tavernScriptPagesProvider = Provider<TavernScriptPages>((ref) {
  ref.watch(tavernProvider);
  return TavernScriptPages();
});

/// Every character, as the library lists them.
final tavernCharactersProvider = StreamProvider<List<TavernCharacter>>(
  (ref) => ref.watch(tavernProvider).watchCharacters(),
);

/// One character in full. The list carries only what a card in the grid
/// shows; greetings, the definition and the creator's notes come from here,
/// read again whenever the list changes (an edit, a re-import).
final tavernCharacterDetailProvider = FutureProvider.autoDispose.family<TavernCharacter?, String>((ref, id) {
  ref.watch(tavernCharactersProvider);
  return ref.watch(tavernProvider).character(id);
});

/// Chats, newest first; one character's when the argument is its id.
final tavernChatsProvider = StreamProvider.family<List<TavernChatSummary>, String?>(
  (ref, characterId) => ref.watch(tavernProvider).watchChats(characterId: characterId),
);

/// Saved personas (人设).
final tavernPersonasProvider = StreamProvider<List<TavernPersona>>((ref) => ref.watch(tavernProvider).watchPersonas());

/// Who you are in a chat (null: outside any chat, just the default). Read
/// again whenever the personas notify, which default and binding changes do.
final tavernPersonaSelectionProvider = FutureProvider.family<PersonaSelection, String?>((ref, chatId) {
  ref.watch(tavernPersonasProvider);
  return ref.watch(tavernProvider).personaSelection(chatId: chatId);
});
