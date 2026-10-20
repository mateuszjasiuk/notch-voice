---
description: Read part of a reply aloud through NotchVoice
argument-hint: what to read, e.g. the part about the migration from the api session
allowed-tools: Bash(nv list:*), Bash(nv history:*), Bash(nv say:*), Bash(nv read:*)
---

<!-- Installed by NotchVoice (https://github.com/NCSmit/notch-voice). -->

The user wants to hear something read aloud through NotchVoice: $ARGUMENTS

1. Find the text.
   - If it comes from this conversation, take it from your own earlier replies.
   - If the user names another session, run `nv list` to see the sessions, then `nv history <session>` to see that session's recent replies. Index 0 is the latest. A session can be given by the start of its name.
2. Take only the part the user asked for. Keep the wording as it is. Don't summarise, shorten or add to it, unless the user asks for that. Leave out code, and write file paths and links in plain words.
3. Read it aloud with `nv say`, passing the text on standard input:

   ```bash
   nv say - <<'NV_TEXT'
   The text to read.
   NV_TEXT
   ```

   If the user wants a whole earlier reply from a session, `nv read <session> [n]` is enough, where `n` is how many replies back it is (1 is the one before the latest).
4. Then answer with one short line saying what you read. That line is not read aloud.

If you can't tell which part the user means, ask them instead of guessing, and don't run `nv say`.
