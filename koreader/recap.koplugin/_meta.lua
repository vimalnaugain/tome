local _ = require("gettext")
return {
    name = "recap",
    fullname = _("Story recap"),
    description = _([[A spoiler-free "previously on…" of the book you are reading, written by an LLM (Claude, any OpenAI-compatible API, or Ollama on your network) from the pages you have already read.]]),
    version = "1.0.0",
}
