import tempfile
import json
import unittest
import subprocess
import sys
from unittest import mock
from pathlib import Path
from bridge import find_reply, pi_answer, pi_environment, pi_failure, pi_command, PI_PROVIDER, PI_MODEL, PI_EFFORT, stop_process_group
from books_context import unique_in_epub, intact_anchors
from oxford_entry import related_score, related_entries, convert, DictionaryUnavailable


def user(text):
    return {"type": "userMessage", "content": [{"type": "text", "text": text}]}


def reply(text):
    return {"type": "agentMessage", "phase": "final_answer", "text": text}


class BridgeTests(unittest.TestCase):
    marker = "[Vocab request 123]"

    def test_correlation_ignores_unrelated_response(self):
        turns = [
            {"id":"other","status":"completed","items":[user("another question"),reply(self.marker)]},
            {"id":"ours","status":"completed","items":[user(self.marker+"\nquestion"),reply("correct reply")]}
        ]
        self.assertEqual(find_reply(turns,self.marker),("completed","ours","correct reply"))

    def test_reconstructed_interrupted_live_turn_keeps_waiting(self):
        turns = [{"id":"ours","status":"interrupted","items":[user(self.marker+"\nquestion")]}]
        self.assertEqual(find_reply(turns,self.marker),("started","ours",""))

    def test_unrelated_user_message_not_a_request(self):
        turns = [{"id":"other","status":"completed","items":[user("quote "+self.marker),reply("wrong")]}]
        self.assertEqual(find_reply(turns,self.marker),("waiting",None,""))

    def pi_event(self, **overrides):
        msg = {"role":"assistant", "provider":PI_PROVIDER, "model":PI_MODEL,
               "stopReason":"stop", "content":[{"type":"thinking","thinking":"hidden"},
                                                {"type":"text","text":"answer"}]}
        msg.update(overrides)
        return json.dumps({"type":"message_end","message":msg})

    def test_pi_selects_final_text_not_startup_logs_or_thinking(self):
        self.assertEqual(pi_answer("extension loaded\n"+self.pi_event()), "answer")

    def test_pi_does_not_accept_other_provider_or_incomplete_reply(self):
        for event in (self.pi_event(provider="qoder"), self.pi_event(model="Other"),
                      self.pi_event(stopReason="error"), self.pi_event(content=[])):
            with self.assertRaises(RuntimeError):
                pi_answer(event)

    def test_pi_environment_resolves_homebrew_from_gui_path(self):
        env = pi_environment({"PATH":"/usr/bin:/bin", "USER":"fixture"})
        self.assertIn("/opt/homebrew/bin", env["PATH"].split(":"))
        self.assertIn("/usr/bin", env["PATH"].split(":"))
        self.assertEqual(env["USER"], "fixture")

    def test_missing_node_is_not_reported_as_subscription_failure(self):
        self.assertIn("Node.js", pi_failure(127, "", "env: node: No such file or directory"))
        self.assertIn("额度", pi_failure(1, "", "429 rate limit"))
        self.assertIn("登录", pi_failure(1, "", "401 unauthorized"))

    def test_requested_thinking_is_high(self):
        self.assertEqual(PI_EFFORT, "high")
        try:
            cmd=pi_command()
        except RuntimeError:
            self.skipTest("Pi not installed in this test environment")
        self.assertEqual(cmd[cmd.index("--thinking")+1], "high")

    def test_builtin_provider_override_keeps_ephemeral_no_tools(self):
        with mock.patch("bridge.shutil.which", return_value="/fake/pi"), mock.patch("bridge.os.access", return_value=True):
            cmd=pi_command("anthropic","claude-fixture","medium")
            self.assertEqual(cmd[cmd.index("--provider")+1],"anthropic")
            self.assertEqual(cmd[cmd.index("--model")+1],"claude-fixture")
            self.assertEqual(cmd[cmd.index("--thinking")+1],"medium")
            self.assertIn("--no-session",cmd)
            self.assertIn("--no-tools",cmd)
            self.assertNotIn("--extension",cmd)
            with self.assertRaises(RuntimeError):pi_command("--bad","test","high")

    def test_stop_owns_only_its_request_group(self):
        child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],start_new_session=True)
        try:
            stop_process_group(child)
            self.assertIsNotNone(child.poll())
        finally:
            if child.poll() is None:
                stop_process_group(child)


class BooksTests(unittest.TestCase):
    def test_unique_text_and_ambiguity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/"fixture.epub"; root.mkdir()
            a=root/"one.xhtml"
            a.write_text("<html><head><title>Example</title></head><h1>Chapter 1</h1><p>I'm ambivalent about moving.</p></html>")
            hit=unique_in_epub(str(root),"ambivalent")
            self.assertEqual(hit["location"],"one.xhtml")
            self.assertEqual(hit["chapter"],"Chapter 1")
            self.assertIn("ambivalent",hit["context"])
            b=root/"two.xhtml";b.write_text("<p>She is ambivalent too.</p>")
            self.assertIsNone(unique_in_epub(str(root),"ambivalent"))
            a.write_text("<p>Yesterday I was still ambivalent about moving abroad.</p>")
            hint = intact_anchors("terday I was still ambivalent about moving abro", "ambivalent")
            anchored = unique_in_epub(str(root), "ambivalent", hint)
            self.assertEqual(anchored["location"], "one.xhtml")
            self.assertIn("Yesterday", anchored["context"])


class DictionaryTests(unittest.TestCase):
    ids = ["com.apple.dictionary.ODE", "com.apple.dictionary.zh_CN-en.OCD", "com.apple.dictionary.OAWT"]

    def sources(self, state="ready", entries=None, plain=""):
        return [{"identifier": ident, "source": ident, "state": state,
                 "assetPresent": state=="ready", "recordCount": len(entries or []),
                 "readFailures": 0, "entries": entries or [], "plain": plain}
                for ident in self.ids]

    def test_uninstalled_resources_are_not_a_healthy_miss(self):
        unavailable = convert(self.sources(state="unavailable"), "imperative")
        self.assertEqual(unavailable["state"], "unavailable")
        self.assertEqual(unavailable["results"], [])
        self.assertEqual(convert(self.sources(), "imperative")["state"], "ready")
        self.assertEqual(convert([], "imperative")["state"], "unavailable")

    def test_malformed_record_preserves_verified_same_source_plain_text(self):
        raw = [{"head":"imperative","rawHead":"imperative","html":"<broken"}]
        result = convert(self.sources(entries=raw, plain="imperative | ɪmˈpɛrətɪv | adjective crucial"), "imperative")
        self.assertEqual(result["state"], "ready")
        self.assertEqual(len(result["results"]), 3)
        self.assertTrue(all(x["match"]=="exact" and not x["content"]["groups"] for x in result["results"]))
        self.assertTrue(all(x["pronunciations"][0]["term"]=="imperative" and x["phonetic"]=="ɪmˈpɛrətɪv" for x in result["results"]))
        self.assertEqual(convert(self.sources(entries=raw), "imperative")["state"], "unreadable")

    def test_public_parent_entry_is_not_an_exact_phrase(self):
        raw = [{"head":"put up with","rawHead":"put","html":"<broken"}]
        report = convert(self.sources(entries=raw,plain="put | pʊt | verb move something"), "put up with")
        self.assertEqual(report["results"], [])
        self.assertEqual(report["state"], "unreadable")
        report = convert(self.sources(plain="Granite State informal a name for New Hampshire"), "granite")
        self.assertEqual(report["results"], [])
        self.assertEqual(report["state"], "unreadable")

    def test_cross_reference_and_unknown_scope_keep_actual_text(self):
        html = '<html><div class="entry"><span class="hw">Granite State</span><div class="se1"><span class="msDict"><span class="xrg">a name for <span class="xr">New Hampshire</span></span></span></div></div></html>'
        raw = self.sources()
        raw[0]["entries"] = [{"head":"Granite State","rawHead":"Granite State","html":html}]
        actual = convert(raw,"granite state")
        self.assertEqual(actual["state"], "ready")
        self.assertEqual(actual["results"][0]["matched"],"Granite State")
        self.assertEqual(actual["results"][0]["content"]["groups"][0]["senses"][0]["meanings"][0]["definition"],"a name for New Hampshire")

    def test_ready_definition_survives_other_unavailable_sources(self):
        raw=self.sources(state="unavailable")
        raw[0].update(state="ready",plain="imperative adjective crucial")
        report=convert(raw,"imperative")
        self.assertEqual(report["state"],"unavailable")
        self.assertEqual(report["results"][0]["matched"],"imperative")

    def test_related_unavailable_is_not_empty_success(self):
        with mock.patch("oxford_entry.subprocess.check_output",return_value=json.dumps(self.sources(state="unavailable")).encode()):
            with self.assertRaises(DictionaryUnavailable):
                related_entries("fixture","take a look","take a look",["take"])

    def test_related_subentries_need_actual_phrase_overlap(self):
        raw, lemma = "She took a long hard look at it", "she take a long hard look at it"
        self.assertGreater(related_score("take a look at", raw, lemma), 0)
        self.assertGreater(related_score("look at", raw, lemma), 0)
        self.assertEqual(related_score("take a seat", raw, lemma), 0)
        self.assertEqual(related_score("take it", raw, lemma), 0)

    def test_related_helper_failure_is_not_empty_success(self):
        with mock.patch("oxford_entry.subprocess.check_output",side_effect=subprocess.TimeoutExpired("fixture",1)):
            with self.assertRaises(subprocess.TimeoutExpired):
                related_entries("fixture","two words","two word",["word"])

if __name__=="__main__":
    unittest.main()
