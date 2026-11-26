"""Convert just the requested local Oxford entries to readable display data."""
import json
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def classes(node):
    return set(node.get("class", "").split())


def plain(node):
    return " ".join("".join(node.itertext()).split())


def of_class(node, cls):
    return (x for x in node.iter() if cls in classes(x))


def norm(s):
    return " ".join(s.replace("’", "'").lower().split())


def find_phrase(entry, term):
    for part in entry.iter():
        if not classes(part) & {"subEntry", "pvsec"}:
            continue
        if any(norm(plain(label)) == norm(term) for label in part.iter()
               if classes(label) & {"l", "pv"}):
            return part
    return None


def distinct(items):
    return list(dict.fromkeys(x for x in items if x))


def headword(entry):
    hw = next(of_class(entry, "hw"), None)
    if hw is None:
        return ""
    return re.sub(r"\s*\d+$", "", plain(hw)) if hw.get("homograph") or hw.get("hm") else plain(hw)


def grammar_kind(label):
    return next((p for p in ("verb", "noun", "adjective", "adverb")
                 if re.search(r"\b" + p + r"\b", label.lower())), "")


def ordinary_forms(head, kind):
    """Validate a single word returned by the dictionary's own search index.
    No guessed stems are looked up, and these rules cannot admit a phrase."""
    h = norm(head)
    if not re.fullmatch(r"[a-z]+(?:-[a-z]+)*", h):
        return set()
    y = len(h) > 1 and h.endswith("y") and h[-2] not in "aeiou"
    forms = set()
    if kind in {"noun", "verb"}:
        forms.add(h[:-1] + "ies" if y else
                  h + "es" if h.endswith(("s", "x", "z", "ch", "sh")) else h + "s")
        if h.endswith("o"):
            forms.add(h + "es")
        if kind == "noun" and h.endswith(("f", "fe")):
            forms.add(h.removesuffix("fe").removesuffix("f") + "ves")
    if kind == "verb":
        forms.add(h[:-1] + "ied" if y else h + "d" if h.endswith("e") else h + "ed")
        forms.add(h[:-2] + "ying" if h.endswith("ie") else
                  h[:-1] + "ing" if h.endswith("e") and not h.endswith(("ee", "oe", "ye")) else h + "ing")
        if h.endswith("e"):
            forms.add(h + "ing")
        if h.endswith("c"):
            forms.update((h + "ked", h + "king"))
    if kind in {"adjective", "adverb"}:
        forms.update((h[:-1] + "ier", h[:-1] + "iest") if y else
                     (h + "r", h + "st") if h.endswith("e") else (h + "er", h + "est"))
    # Oxford has already returned this headword for the actual lookup; allow
    # the orthographic doubling used by forms such as stopped / bigger.
    if len(h) >= 3 and h[-1] not in "aeiouwxy" and h[-2] in "aeiou" and h[-3] not in "aeiou":
        suffixes = ("ed", "ing") if kind == "verb" else ("er", "est") if kind in {"adjective", "adverb"} else ()
        forms.update(h + h[-1] + suffix for suffix in suffixes)
    return forms


def ancestors(node, parents):
    while node in parents:
        node = parents[node]
        yield node


def inflection_evidence(target, term, parents, language):
    """Find the explicitly listed inflection, excluding unrelated subentries."""
    found, kinds = False, set()
    for node in of_class(target, "inf"):
        if norm(plain(node)) != norm(term):
            continue
        chain = list(ancestors(node, parents))
        if any(classes(a) & {"subEntry", "pvsec", "feature", "note"} for a in chain if a is not target):
            continue
        found = True
        scope = next((a for a in chain if classes(a) & {"se1", "gramb"}), None)
        if scope is not None:
            pos = next(of_class(scope, "ps" if language == "zh" else "pos"), None)
            if pos is not None:
                kinds.add(grammar_kind(plain(pos)))
    return found, kinds - {""}


def pronunciation_values(entry, target, head, term, parents):
    """Keep IPA tied to the actual written form, not a different lemma or derivative."""
    values = []
    is_phrase = target is not entry
    blocked = {"subEntry", "pvsec", "feature", "note", "etym", "msDict", "msThes", "exg"}
    for node in of_class(target, "ph"):
        chain = list(ancestors(node, parents))
        within = chain[:chain.index(target)] if target in chain else []
        if any(classes(a) & blocked for a in within):
            continue
        ipa = plain(node).strip(" |/,;")
        if not ipa or ipa.startswith("-") or len(ipa) > 100:
            continue
        infg = next((a for a in within if "infg" in classes(a)), None)
        if infg is not None:
            # A pronunciation belongs only to the preceding explicitly
            # labelled inflection, not every form in the inflection block.
            form = None
            for member in infg.iter():
                if member is node:
                    break
                if "inf" in classes(member):
                    form = plain(member)
            if not form or norm(form) != norm(term):
                continue
            spoken = term
        else:
            spoken = term if is_phrase else head
        value = {"ipa": ipa, "term": spoken, "dialect": node.get("dialect", "")}
        if value not in values:
            values.append(value)
    return values


def regular_pronunciations(pronunciations, head, term, kinds):
    """Only derive predictable English endings when the dictionary's stem
    and compatible POS have already been validated. Never label this as IPA
    published in the dictionary."""
    h, q = norm(head), norm(term)
    ending = ""
    if q.endswith("ed") and "verb" in kinds and q in ordinary_forms(h, "verb"):
        ending = "ed"
    elif q.endswith("s") and any(q in ordinary_forms(h, k) for k in kinds & {"noun", "verb"}):
        if not (q.endswith("ves") and h.endswith(("f", "fe"))):
            ending = "s"
    if not ending:
        return []
    # Irregular sound changes are not captured by the regular suffix rule.
    # Use an attested pronunciation (or the labelled base IPA) instead.
    if ending == "s" and (h in {"do", "say", "house"} or h.endswith("th")):
        return []
    results = []
    for p in pronunciations:
        ipa = p["ipa"]
        if norm(p["term"]) != h or re.search(r"[(),;/|\s-]", ipa):
            continue
        if ending == "ed":
            suffix = "ɪd" if ipa.endswith(("t", "d")) else "t" if ipa.endswith(("p", "k", "f", "s", "ʃ", "θ")) else "d"
        else:
            suffix = "ɪz" if ipa.endswith(("s", "z", "ʃ", "ʒ")) else "s" if ipa.endswith(("p", "t", "k", "f", "θ")) else "z"
        prefix = "ˈ" if suffix.startswith("ɪ") and not any(c in ipa for c in ("ˈ", "ˌ")) else ""
        results.append({**p, "ipa": prefix + ipa + suffix, "term": term, "derived": True})
    return results


def translations(node):
    """Chinese glosses only; never pull example text or pronunciation into a gloss."""
    result = []
    def visit(n):
        if "exg" in classes(n):
            return
        if "trans" in classes(n) and "ty_pinyin" not in classes(n):
            result.append(plain(n))
            return
        for c in n:
            visit(c)
    visit(node)
    return distinct(result)


def meaning(node, language):
    tags = classes(node)
    labels = distinct(plain(x) for x in node
                      if classes(x) & {"gg", "lg", "fg", "cnt", "reg", "fld", "ind"})
    examples = distinct(plain(x) for x in of_class(node, "ex"))
    synonyms = distinct(plain(x).rstrip("; ") for x in of_class(node, "synGroup"))
    antonyms = distinct(plain(x) for x in of_class(node, "ant"))
    if language == "zh":
        desc = "；".join(translations(node))
        examples = []
        for ex in of_class(node, "exg"):
            english = next(of_class(ex, "ex"), None)
            if english is not None:
                gloss = distinct(t for child in ex for t in translations(child))
                examples.append(plain(english) + (" — " + "；".join(gloss) if gloss else ""))
        # Domain labels in the bilingual dictionary occur inside the translation group.
        labels = distinct(plain(x) for x in node.iter()
                          if classes(x) & {"reg", "fld", "ind"} and plain(x))[:3]
    else:
        defs = distinct(plain(x) for x in of_class(node, "df"))
        # Some real Oxford headwords are cross-reference entries, e.g.
        # Granite State. Their meaning is in xrg instead of df.
        if not defs and language == "en":
            defs = distinct(plain(x) for x in of_class(node, "xrg"))
        desc = " ".join(defs)
    if not (desc or synonyms or antonyms):
        return None
    return {"definition": desc, "qualifiers": labels, "examples": examples,
            "synonymGroups": synonyms, "antonyms": antonyms,
            "subordinate": "t_subsense" in tags}


def groups(target, language):
    # Preserve only the immediate grammatical/sense hierarchy. Otherwise
    # a long root's phrases leak into its ordinary part-of-speech groups.
    def walk(n, wanted, stop):
        for child in n:
            tags = classes(child)
            if tags & wanted:
                yield child
            elif not tags & stop:
                yield from walk(child, wanted, stop)
    stop = {"subEntryBlock", "pvb", "subEntry", "pvsec", "feature", "note", "etym"}
    scope_tag = "gramb" if language == "zh" else "se1"
    scopes = list(walk(target, {scope_tag}, stop)) or [target]
    out = []
    for scope in scopes:
        pos = next(of_class(scope, "ps" if language == "zh" else "pos"), None)
        label = plain(pos) if pos is not None else ""
        if language == "zh":
            nodes = list(walk(scope, {"semb"}, stop)) or [scope]
            numbered = [{"number": i + 1, "meanings": [m]} for i, node in enumerate(nodes)
                        if (m := meaning(node, language))]
        else:
            wanted = {"msThes"} if language == "writer" else {"msDict"}
            sense_scopes = list(walk(scope, {"se2"}, stop)) or [scope]
            numbered = []
            for i, sense in enumerate(sense_scopes):
                nodes = list(walk(sense, wanted, stop))
                meanings = [m for node in nodes if (m := meaning(node, language))]
                if meanings:
                    numbered.append({"number": i + 1, "meanings": meanings})
        if numbered:
            out.append({"partOfSpeech": label, "senses": numbered})
    return out


def extra_sections(target):
    out = []
    def visit(n):
        tags = classes(n)
        if tags & {"subEntryBlock", "pvb", "etym", "note", "feature"}:
            title_node = next((x for x in n if "ty_label" in classes(x) or
                               "feature-title" in classes(x)), None)
            title = plain(title_node) if title_node is not None else (
                "Origin" if "etym" in tags else "Usage" if "note" in tags else "Notes")
            items = []
            for part in n:
                if classes(part) & {"subEntry", "pvsec"}:
                    header = next((x for x in part.iter() if classes(x) & {"l", "pv"}), None)
                    heading = plain(header) if header is not None else ""
                    detail = formatted(part)
                    if heading and detail.startswith(heading):
                        detail = detail[len(heading):].strip()
                    if detail:
                        items.append({"heading": heading, "text": detail})
            if not items:
                detail = formatted(n)
                if title and detail.lower().startswith(title.lower()):
                    detail = detail[len(title):].strip()
                if detail:
                    items.append({"heading": "", "text": detail})
            if items:
                out.append({"title": title, "items": items})
            return
        for child in n:
            visit(child)
    visit(target)
    return out


def formatted(node):
    # The original dictionary provides section names and punctuation. Preserve
    # those, rather than inventing or mixing meanings/usage across sources.
    blocks = {"hg", "se1", "msDict", "msThes", "subEntryBlock", "subEntry",
              "etym", "note", "feature", "feature-title", "feature-body",
              "antList", "item", "heading", "posg"}
    pieces = []

    def visit(n):
        if classes(n) & blocks:
            pieces.append("\n")
        if n.text:
            pieces.append(n.text)
        for child in n:
            visit(child)
            if child.tail:
                pieces.append(child.tail)
        if classes(n) & {"subEntryBlock", "etym", "note", "feature"}:
            pieces.append("\n")

    visit(node)
    return "\n".join(line for raw in "".join(pieces).splitlines()
                     if (line := " ".join(raw.split())))


def entry_data(raw, term, language="en"):
    root = ET.fromstring(raw["html"])
    entry = next(of_class(root, "entry"), None)
    if entry is None:
        return None
    head = headword(entry)
    if not head:
        return None
    parents = {child: parent for parent in entry.iter() for child in parent}
    phrase = find_phrase(entry, term) if " " in term else None
    if phrase is not None:
        target, matched, match = phrase, term, "exact"
    elif norm(head) == norm(term):
        target, matched, match = entry, head, "exact"
    elif " " not in term and " " not in head:
        # The system search may return the lemma as BOTH record names (e.g.
        # 'eluded' -> 'elude'). Require dictionary-listed or regular,
        # POS-compatible morphology, or an exact index alias.
        explicit, kinds = inflection_evidence(entry, term, parents, language)
        grouped = groups(entry, language)
        regular = {grammar_kind(g["partOfSpeech"]) for g in grouped
                   if norm(term) in ordinary_forms(head, grammar_kind(g["partOfSpeech"]))}
        alias = norm(raw["head"]) == norm(term) or norm(raw["rawHead"]) == norm(term)
        if not (explicit or regular or alias):
            return None
        allowed = kinds | regular
        target, matched, match = entry, head, "inflected"
    else:
        # Do not treat a root's unrelated definition as a phrase definition.
        return None
    grouped = groups(target, language)
    if match == "inflected" and allowed:
        grouped = [g for g in grouped if grammar_kind(g["partOfSpeech"]) in allowed]
    summaries = []
    for group in grouped:
        senses = group["senses"][:3] if phrase is not None else group["senses"][:1]
        for sense in senses:
            m = sense["meanings"][0]
            content = m["definition"] or "; ".join(m["synonymGroups"])
            prefix = group["partOfSpeech"]
            summaries.append((prefix + " · " if prefix else "") + content)
    pronunciations = pronunciation_values(entry, target, head, term, parents)
    if match == "inflected" and regular and not any(norm(p["term"]) == norm(term) for p in pronunciations):
        pronunciations += regular_pronunciations(pronunciations, head, term, regular)
    detail = formatted(target)
    if not summaries and any(plain(n) for n in target.iter()
                             if classes(n) & {"df", "msDict", "msThes", "semb"}):
        # The exact target is already verified above. Preserve its actual
        # scoped text if a future Oxford markup variant defeats grouping.
        summaries = [detail] if detail else []
    if not summaries and not pronunciations:
        return None
    example = next(of_class(target, "ex"), None)
    return {
        "matched": matched, "match": match, "summary": summaries[:3],
        "detail": detail, "pronunciations": pronunciations,
        "example": plain(example) if example is not None else None,
        "groups": grouped, "sections": extra_sections(target),
    }


def plain_fallback(source, term, matched_entries):
    """Only accept a verifiable head in the same dictionary's public text.

    The public API may return the entire parent entry for a phrase (put up
    with -> put). Never present that as the phrase's exact definition.
    """
    detail = source.get("plain", "").strip()
    if not detail:
        return None
    candidates = [(term, "exact")]
    candidates += [(e["matched"], e["match"]) for e in matched_entries
                   if e["match"] == "inflected"]
    for head, match in candidates:
        prefix = re.escape(head).replace(r"\ ", r"\s+")
        # A word boundary alone would accept 'Granite State' for 'granite'.
        # Require the actual heading delimiter, not a bare prefix.
        m = re.match(r"^" + prefix + r"\s+(?=\||\[|(?:noun|verb|adjective|adverb|pronoun|preposition|conjunction|determiner|interjection|exclamation|article|abbreviation|informal|formal|plural)\b)",
                     detail, re.I)
        if not m:
            continue
        body = detail[m.end():].strip()
        if not body or len(body) < 8:
            continue
        # Keep an explicitly delimited Oxford pronunciation, never guess a
        # stem pronunciation or merge dialect labels from the flat text.
        ipa_match = re.match(r"^\|\s*([^|]{1,100})\s*\|",body)
        ipa = ipa_match.group(1).strip() if ipa_match else ""
        if re.search(r"\b(?:BrE|AmE)\b",ipa):
            ipa = ""
        pronunciations = ([{"ipa":ipa,"term":head,"dialect":"","source":source["source"]}] if ipa else [])
        return {"source": source["source"], "identifier":source["identifier"],
                "matched":head, "match":match, "body":body[:380], "detail":detail,
                "phonetic":ipa, "pronunciations":pronunciations, "example":None,
                "content":{"groups":[],"sections":[]}}
    return None


def convert(raw, term):
    result = []
    statuses = []
    for source in raw:
        entries, errors = [], source.get("readFailures", 0)
        raw_exact = False
        for item in source["entries"]:
            raw_exact |= norm(item["head"]) == norm(term) or norm(item["rawHead"]) == norm(term)
            try:
                language = ("writer" if source["identifier"].endswith(".OAWT") else
                            "zh" if source["identifier"].endswith(".OCD") else "en")
                e = entry_data(item, term, language)
            except (ET.ParseError, ValueError):
                errors += 1
                continue
            if e:
                entries.append(e)
        # Resource readiness and lexical matching are separate. An entry's
        # shape is not evidence that a word is absent.
        state = source.get("state", "unavailable")
        usable = [e for e in entries if e["summary"]]
        if not usable:
            fallback = plain_fallback(source, term, entries)
            if fallback:
                result.append(fallback)
                state = "ready"
            elif state == "ready" and (errors or raw_exact or entries or
                                      (source.get("plain") and not source["entries"])):
                state = "unreadable"
            statuses.append({"identifier":source["identifier"],"state":state,
                             "assetPresent":source.get("assetPresent",False),
                             "recordCount":source.get("recordCount",0),"parseFailures":errors,
                             "result":"plain" if fallback else "none"})
            continue
        matching_case = [e for e in entries if e["matched"].isupper() == term.isupper()]
        if any(e["summary"] for e in matching_case):
            entries = matching_case
        # Exact headwords precede inflected homographs. Retain alternatives
        # with distinct lemma labels instead of mixing their identities.
        entries.sort(key=lambda e: (
            e["matched"].isupper() != term.isupper(),
            e["match"] != "exact"))
        usable = [e for e in entries if e["summary"]]
        first = (usable or entries)[0]
        summaries = list(dict.fromkeys(s for e in usable for s in e["summary"]))
        grouped = []
        for e in usable:
            for group in e["groups"]:
                if norm(e["matched"]) != norm(first["matched"]):
                    group = {**group, "partOfSpeech": group["partOfSpeech"] + " · " + e["matched"]}
                grouped.append(group)
        pronunciations = []
        for e in entries:
            for p in e["pronunciations"]:
                p = {**p, "source": source["source"]}
                if p not in pronunciations:
                    pronunciations.append(p)
        chosen = next((p["ipa"] for p in pronunciations if norm(p["term"]) == norm(term)), "")
        if not chosen:
            chosen = next((p["ipa"] for p in pronunciations if norm(p["term"]) == norm(first["matched"])), "")
        result.append({"source": source["source"], "identifier": source["identifier"],
                       "matched": first["matched"], "match": first["match"],
                       "body": "\n".join(summaries[:3]),
                       "detail": "\n\n".join(dict.fromkeys(e["detail"] for e in usable)),
                       "phonetic": chosen, "pronunciations": pronunciations, "example": first["example"],
                       "content": {"groups": grouped,
                                   "sections": [s for e in usable for s in e["sections"]]}})
        statuses.append({"identifier":source["identifier"],"state":"ready",
                         "assetPresent":source.get("assetPresent",False),
                         "recordCount":source.get("recordCount",0),"parseFailures":errors,
                         "result":"structured" if grouped else "plain"})
    primary = next((e for e in result if e["identifier"].endswith(".ODE") and e["content"]["groups"]), None)
    if primary and primary["match"] == "inflected":
        kinds = {grammar_kind(g["partOfSpeech"]) for g in primary["content"]["groups"]}
        for e in result:
            if e is not primary and e["match"] == "inflected" and norm(e["matched"]) == norm(primary["matched"]):
                # In particular, irregular indexed forms may have noun
                # homographs in the thesaurus; follow the primary's evidence.
                compatible = [g for g in e["content"]["groups"] if grammar_kind(g["partOfSpeech"]) in kinds]
                if compatible:
                    e["content"]["groups"] = compatible
    # Report every explicitly requested dictionary, even if previously
    # advertised but absent/unavailable. Never collapse that to empty success.
    expected = {"com.apple.dictionary.ODE","com.apple.dictionary.OAWT","com.apple.dictionary.zh_CN-en.OCD"}
    seen = {s["identifier"] for s in statuses}
    statuses.extend({"identifier":ident,"state":"unavailable","assetPresent":False,
                     "recordCount":0,"parseFailures":0,"result":"none"} for ident in sorted(expected-seen))
    state = ("unavailable" if any(s["state"] == "unavailable" for s in statuses) else
             "unreadable" if any(s["state"] != "ready" for s in statuses) else "ready")
    return {"results":sorted(result, key=lambda e: not e["identifier"].endswith(".ODE")),
            "state":state,"sources":statuses}


def related_score(label, term, lemmas):
    """A labelled phrase must occur in the selection, not merely share
    incidental words such as 'take', 'a', or 'it'."""
    tokens = lambda s: re.findall(r"[a-z]+", s.lower())
    phrase = tokens(label)
    if len(phrase) < 2:
        return 0
    for query in (tokens(lemmas), tokens(term)):
        if any(query[i:i + len(phrase)] == phrase for i in range(len(query))):
            return 100 + len(phrase)
        content = set(phrase) - {"a", "an", "the", "it", "of", "on", "in", "at", "to", "for", "with", "by", "be", "one", "s", "someone", "something"}
        if len(content) < 2 or not content.issubset(query):
            continue
        for i, token in enumerate(query):
            if token != phrase[0]:
                continue
            cursor = i + 1
            for word in phrase[1:]:
                match = next((j for j in range(cursor, min(cursor + 4, len(query))) if query[j] == word), None)
                if match is None:
                    break
                cursor = match + 1
            else:
                return 60 + len(phrase)
    return 0


class DictionaryUnavailable(Exception):
    pass


def related_entries(helper, term, lemmas, heads):
    """Surface only actual labelled Oxford subentries; no headword definition
    is allowed to masquerade as an exact expression result."""
    results = []
    errors = []
    for head in heads[:3]:
        try:
            sources = json.loads(subprocess.check_output([str(helper), head], timeout=1.5))
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            errors.append(error)
            continue
        preferred = next((s for s in sources if s["identifier"].endswith(".ODE")),None)
        if not preferred or preferred.get("state") != "ready":
            errors.append(DictionaryUnavailable("Oxford resource is not ready"))
            continue
        if preferred.get("readFailures", 0):
            errors.append(ValueError("Oxford related record could not be read"))
        for source in sources:
            if not source["identifier"].endswith(".ODE"):
                continue
            for entry in source["entries"]:
                try:
                    root = ET.fromstring(entry["html"])
                except (ET.ParseError, ValueError) as error:
                    errors.append(error)
                    continue
                for part in root.iter():
                    if not classes(part) & {"subEntry", "pvsec"}:
                        continue
                    label = next((plain(x) for x in part.iter() if classes(x) & {"l", "pv"}), "")
                    score = related_score(label, term, lemmas)
                    if not score:
                        continue
                    detail = formatted(part)
                    if detail.startswith(label):
                        detail = detail[len(label):].strip()
                    if not detail:
                        continue
                    results.append((score, {"head": head, "label": label, "text": detail[:700], "source": source["source"]}))
    seen, selected = set(), []
    for score, item in sorted(results, key=lambda pair: -pair[0]):
        if item["label"].lower() in seen:
            continue
        selected.append(item);seen.add(item["label"].lower())
        if len(selected) == 4:
            break
    if not selected and errors:
        raise errors[0]
    return selected


if __name__ == "__main__":
    helper = pathlib.Path(__file__).resolve().parent.parent / "Helpers" / "DictionaryBridge"
    if len(sys.argv) >= 5 and sys.argv[1] == "--related":
        try:
            print(json.dumps({"state":"ready","results":related_entries(helper, sys.argv[2], sys.argv[3], sys.argv[4:])}, ensure_ascii=False))
            sys.exit(0)
        except DictionaryUnavailable:
            print(json.dumps({"state":"unavailable","results":[]}))
            sys.exit(0)
        except subprocess.TimeoutExpired:
            sys.exit(124)
        except (OSError, subprocess.SubprocessError, ValueError):
            sys.exit(1)
    if len(sys.argv) != 2:
        sys.exit(2)
    term = sys.argv[1]
    try:
        raw = json.loads(subprocess.check_output([str(helper), term], timeout=4))
        print(json.dumps(convert(raw, term), ensure_ascii=False))
    except subprocess.TimeoutExpired:
        sys.exit(124)
    except (OSError, subprocess.SubprocessError, ValueError):
        sys.exit(1)
