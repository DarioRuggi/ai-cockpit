// =============================================================================
// Intercom — talk to the rig, hands free.
//
// Press once: Cockpit listens, notices when you stop talking, transcribes what
// you said, sends it, speaks the answer, and listens again. Press again to stop.
// Every piece already existed — Web Audio capture, whisper, piper — what was
// missing was the loop between them.
//
// Two decisions worth knowing:
//
// SILENCE, NOT A TIMER. The turn ends when you stop speaking (about 1.5s under
// the noise floor), not after a fixed number of seconds, because a fixed window
// either cuts people off or makes them wait. A minimum length stops a cough from
// being sent as a prompt.
//
// IT SPEAKS THE ANSWER, NOT THE MARKUP. Code blocks, tables and marker syntax
// are stripped before the text goes to the voice: hearing a model read out
// backticks and pipe characters is useless, and long answers are cut with a
// spoken note rather than read for four minutes.
// =============================================================================

let _icOn = false;          // the loop is running
let _icCap = null;          // active capture handle
let _icAudio = null;        // the <audio> element currently speaking
let _icWaiting = false;     // waiting for an agent answer

const IC_SILENCE_MS   = 1500;   // quiet for this long = you have finished
const IC_MIN_SPEECH_MS = 400;   // shorter than this is a noise, not a sentence
const IC_MAX_TURN_MS  = 30000;  // hard stop so a stuck mic cannot record forever

function intercomToggle() {
    if (_icOn) { intercomStop('stopped'); return; }
    if (!navigator.mediaDevices || !(window.AudioContext || window.webkitAudioContext)) {
        appendError(T('msg.intercom.this.browser.cannot.capture.audio', 'Intercom: this browser cannot capture audio.')); return;
    }
    _icOn = true;
    _icSetBtn(true);
    appendSystem(T('msg.icon.record.voice.over.intercom.on.speak.and', '[[icon:record_voice_over]] Intercom on — speak, and pause when you are done. Press again to stop.'));
    _icListen();
}

function intercomStop(why) {
    _icOn = false;
    _icSetBtn(false);
    try { if (_icCap) _icCap.stop(); } catch (e) {}
    _icCap = null;
    if (_icStream) { _icStream.getTracks().forEach(t => t.stop()); _icStream = null; }
    if (_icAudio) { try { _icAudio.pause(); } catch (e) {} _icAudio = null; }
    if (why !== 'quiet') appendSystem(T('msg.icon.record.voice.over.intercom.off', '[[icon:record_voice_over]] Intercom off.'));
}

function _icSetBtn(on) {
    const b = document.getElementById('intercom-btn');
    if (!b) return;
    b.style.borderColor = on ? 'var(--ollama)' : '';
    b.style.color       = on ? 'var(--ollama)' : '';
    b.title = on ? 'Intercom is listening — click to stop' : 'Intercom — talk to the rig, hands free';
}

let _icStream = null;

/** Record one turn, ending when the speaker stops. */
async function _icListen() {
    if (!_icOn) return;
    try {
        _icStream = await navigator.mediaDevices.getUserMedia(
            (typeof _micConstraint === 'function') ? _micConstraint() : { audio: true });
    } catch (e) { appendError(T('msg.intercom.no.microphone.message', 'Intercom: no microphone — {message}', {message: e.message})); intercomStop(); return; }

    let lastLoud = Date.now();
    const started = Date.now();
    let heardAnything = false;

    _icCap = _micCapture(_icStream, level => {
        if (typeof _micLevelSet === 'function') _micLevelSet(level);
        if (level > 0.035) { lastLoud = Date.now(); heardAnything = true; }
    });
    if (typeof _micLevelShow === 'function') _micLevelShow(true);

    const tick = setInterval(async () => {
        if (!_icOn) { clearInterval(tick); return; }
        const now = Date.now();
        const quietFor = now - lastLoud;
        const tooLong  = now - started > IC_MAX_TURN_MS;
        if (!(quietFor > IC_SILENCE_MS && heardAnything) && !tooLong) return;

        clearInterval(tick);
        const cap = _icCap; _icCap = null;
        const rec = await cap.stop();
        if (_icStream) { _icStream.getTracks().forEach(t => t.stop()); _icStream = null; }
        if (typeof _micLevelShow === 'function') _micLevelShow(false);

        // Nothing worth sending: go straight back to listening rather than
        // making the person press the button again after a cough.
        if (!heardAnything || rec.seconds * 1000 < IC_MIN_SPEECH_MS) { _icListen(); return; }

        await _icSendTurn(rec);
    }, 200);
}

async function _icSendTurn(rec) {
    if (!_icOn) return;
    try {
        const fd = new FormData();
        fd.append('audio', rec.blob, 'intercom.wav');
        const langSel = document.getElementById('mic-lang');
        fd.append('language', langSel ? langSel.value : 'auto');
        fd.append('model', (document.getElementById('mic-model') || {}).value || 'auto');
        const d = await (await fetch('transcribe.php', { method: 'POST', body: fd })).json();
        const text = (d.ok ? (d.text || '') : '').trim();
        // Whisper does not return silence — it returns a GUESS about silence, and
        // the guess is a word. A quiet room here transcribed as "*Crickets*",
        // which was sent as the prompt and cheerfully answered. [BLANK_AUDIO],
        // (silence), *sighs*, [MUSIC] are whisper DESCRIBING the audio, not the
        // person speaking. Strip the annotations; if no letters survive, nobody
        // said anything (2026-09-29).
        const spoken = text.replace(/\[[^\]]*\]|\([^)]*\)|\*[^*]*\*/g, ' ').trim();
        if (!text || !/\p{L}/u.test(spoken)) {
            // Said plainly and then back to listening — silence here would look
            // like the feature had died.
            appendSystem(T('msg.icon.record.voice.over.nothing.recognised.se', '[[icon:record_voice_over]] Nothing recognised ({seconds}s) — still listening.', {seconds: rec.seconds}));
            _icListen(); return;
        }
        // The prompt box is #prompt-in — #promptInput never existed. This file was
        // never loaded until b131, so the wrong id sat here unnoticed: the
        // transcribed speech went into null, sendPrompt() fired on an empty box,
        // and nothing was sent.
        const input = document.getElementById('prompt-in');
        if (input) input.value = spoken;
        _icWaiting = true;
        if (typeof sendPrompt === 'function') sendPrompt();
    } catch (e) {
        appendError(T('msg.intercom.message', 'Intercom: {message}', {message: e.message}));
        _icListen();
    }
}

/** Strip what should not be read aloud, and keep it short enough to listen to. */
function _icSpeakable(text) {
    let t = String(text || '');
    t = t.replace(/```[\s\S]*?```/g, ' … code block … ');   // never read code out
    t = t.replace(/%%[A-Z_]+:[^%]*%%/g, ' ');                // marker syntax
    t = t.replace(/\|[^\n]*\|/g, ' … table … ');             // tables are unlistenable
    t = t.replace(/[*_#>`]/g, '');                           // markdown punctuation
    t = t.replace(/\[\[icon:[a-z_]+\]\]/g, '');
    t = t.replace(/\s+/g, ' ').trim();
    const LIMIT = 900;                                       // ~1 minute of speech
    if (t.length > LIMIT) t = t.slice(0, LIMIT) + ' … the rest is on screen.';
    return t;
}

/** Called when an answer lands: speak it, then listen again. */
async function intercomMaybeSpeak(answerText) {
    if (!_icOn || !_icWaiting) return;
    _icWaiting = false;
    const say = _icSpeakable(answerText);
    if (!say) { _icListen(); return; }
    try {
        const g = await (await fetch('generate.php?action=start', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ kind: 'sound', sound_type: 'speech', language: 'auto', prompt: say }),
        })).json();
        if (!g.ok || !g.id) { appendError(T('msg.intercom.could.not.speak.the.answer.error', 'Intercom: could not speak the answer — {error}', {error: (g.error || '?')})); _icListen(); return; }

        // Wait for piper, but not forever: if the voice is not ready the loop
        // must keep working, deaf rather than stuck.
        let file = '';
        for (let i = 0; i < 90 && _icOn; i++) {
            const s = await (await fetch('generate.php?action=status&id=' + encodeURIComponent(g.id))).json();
            if (s.state === 'done' || s.file) { file = s.file || ('generate.php?action=file&id=' + g.id); break; }
            if (s.state === 'error' || s.state === 'cancelled') break;
            await new Promise(r => setTimeout(r, 400));
        }
        if (!file) { appendSystem(T('msg.icon.record.voice.over.the.answer.is.on.scre', '[[icon:record_voice_over]] The answer is on screen — speaking it failed.')); _icListen(); return; }

        _icAudio = new Audio(file.startsWith('generate.php') ? file : ('generate.php?action=file&id=' + g.id));
        _icAudio.onended = () => { _icAudio = null; if (_icOn) _icListen(); };
        _icAudio.onerror = () => { _icAudio = null; if (_icOn) _icListen(); };
        await _icAudio.play();
    } catch (e) {
        appendError(T('msg.intercom.message', 'Intercom: {message}', {message: e.message}));
        if (_icOn) _icListen();
    }
}
