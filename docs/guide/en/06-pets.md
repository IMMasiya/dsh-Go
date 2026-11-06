# Pets

Pick a pet to keep you company in chats. When a turn finishes, fails, or waits for your approval or answer, it pops up a bubble. It can also float outside the app.

## Choose a pet

<!-- nav: commonSettings,botsPets -->
`Settings › Pets` · [Open](dshgo://open/pets)

Tap **Pets** in the Appearance group of Settings, or touch and hold the pet in a chat and choose **Pet settings**. Choose a pet first; the other settings appear below it.

- Choose **Deepy**, **Whale girl** or **None**.
- **Size**: **Small**, **Standard** or **Large**. Standard by default.
- **Quiet mode**: animations only, no bubbles.

The pet, size and Quiet mode apply both in and outside the app.

## In chats

- The pet sits above the composer; drag it left or right to move it.
- Tap a bubble to jump to its chat; swipe up to dismiss it.
- Touch and hold the pet for **Change pet**, **Hide for 1 hour** and **Pet settings**. While it's hidden, **Show now** appears on the pet page.

## Show outside the app

1. On the pet page, turn on **Show outside the app** (off by default).
2. Allow "Display over other apps" when asked. If phone control's accessibility service is on, no extra permission is needed. Without permission, the switch turns itself off and shows **Not allowed**.
3. Under **When to show**, choose **When active** (default) or **Always**. When active: shows while a reply is running, a bubble is up, or there was activity in the last 5 minutes.

The floating pet hides while the app is in the foreground and during phone control tasks.

Floating pet: tap to open the chat that needs you most (approvals and questions first); drag it and it snaps to the edge and stays there; drag it onto the × or touch and hold and choose **Hide for today** to hide it for the day. Tap **Restore** on the pet page to bring it back.

On Android 13 and later, if the switch still won't turn on after visiting system settings, **Switch disabled** appears on the pet page. Tap it for brand-specific steps to **Allow restricted settings**.

## Quick ask, bubble decisions and voice

Long-press the floating pet and choose Quick ask to open its input bar. The target line names the conversation and host; switch to a new conversation if needed. Messages go through normal chat and appear in its history. If the host or connection changes, reopen the bar to confirm the target. Back or a tap outside closes the bar.

Approval bubbles show complete tool arguments when a request can be handled there. Missing or lengthy arguments and requests needing detailed interaction open the app instead. Simple single-choice questions can be answered in the bubble. Expired requests cannot be submitted.

The microphone uses the phone's installed offline speech model and does not fall back to a cloud provider. If the model is unavailable, follow the setup guidance. If Android blocks background recording or returns silence, a separate foreground recording dialog brings recognized text back to the input bar. Sending still requires your action, and an existing chat draft is preserved.

## Companion room

The companion room is a separate full page with an animated Live2D character. It isn't the status pet above: the pet watches the agent for you, and the room is a place to spend a little time.

Open the **Switch host** panel and tap **Companion room**. The first time, import an asset pack (zip). Character assets aren't part of the app and stay on this phone; you can remove them from the menu at the top right of the room.

What you can do:

- Touch her: stroke her head to pat it, and tap her face, body or tail for different reactions. Three quick pokes make her dizzy. None of this calls a model or spends tokens.
- Talk to her: type or use voice in the bar at the bottom. Choose how in **How she talks** in the menu at the top right:
  - **Light**: chat only. The phone uses the DeepSeek API key you saved in Settings to talk to the model directly, with no engine and no host. The chat stays on this phone, and **Start over** deletes it. Not available when you signed in with a DeepSeek account and saved no key.
  - **Full**: uses DSH on the current host, in its own conversation that stays out of the chat list. **View chat history** in the menu opens it, and **Start over** begins a new conversation while the old record stays on the host. Tools and phone control come later.
  - Until you choose, she uses Full while a host is connected and Light otherwise.
- Zoom: pinch to zoom and move.
- Her corner: there's a snack in the shell at the bottom left, a bubble floating on the right, and a seaweed cushion behind her. Tap the shell to give her a snack, the bubble to play, and the cushion to let her rest for a while. What she's doing shows under her name.

She notices that you visit and pat her, and slowly gets more familiar with you; staying away for a few days doesn't upset her. Write down things you want her to remember in **What she remembers** in the menu. You can edit or delete them anytime, and they stay on the current host (Full mode only). She doesn't bring these up by herself yet, can't speak aloud and only shows text, and can't touch your files or phone.

If this host's engine is older, she runs on the default preset and may ask to use tools. When "Something needs your confirmation" appears, tap it and handle the request in the regular chat.
