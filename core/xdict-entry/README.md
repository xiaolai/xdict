# xdict-entry

Turns a record into an entry a view can show: classifies every link (`entry://`, `sound://`, `.tts`, relative
paths, remote URLs), rewrites them under the view's base in the entry and in the stylesheets and scripts it
loads, expands a dictionary's compact `StyleSheet`, and keeps resource paths canonical and encoded (ADR-0007
decisions 6–8 and 14). Redirects are followed by `xdict-lookup`.
