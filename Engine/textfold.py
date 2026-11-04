"""Accent folding shared by the index and the classifier.

SQLite's unicode61 tokenizer with remove_diacritics folds Latin accents but not the Greek tonos or
polytonic marks: "ιστορια" did not find "ιστορία". So text is folded before it reaches FTS5 (NFD, then
every combining mark dropped), and the app folds queries the same way (QueryParser.fold).
"""
import unicodedata


def fold(text: str | None) -> str | None:
    if text is None:
        return None
    return "".join(ch for ch in unicodedata.normalize("NFD", text) if not unicodedata.combining(ch))
