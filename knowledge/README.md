# knowledge/

Every `*.md` / `*.txt` file here (sorted by name, `README*` excluded) is sent
in full as `[MEETING BACKGROUND]` to both the translation and the reply-hint
prompts. Files are re-read on every request, so edits apply immediately.

`instructions.md` is special: its text is appended to both prompts as
`[ADDITIONAL INSTRUCTIONS]`. Use it to steer style, for example:

```markdown
- 可以这样说 uses です/ます and stays under two sentences.
- Translate 案件 as 项目, not 案子.
```

Keep the folder small: everything is injected into every request.
