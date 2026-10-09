<script lang="ts">
  // After a table plays a game's test build, every phone there is asked how
  // it went. The answer goes straight to the game's developer.
  import { playtestFeedback } from './state';
  let dialog: HTMLDialogElement;
  let rating = 0;
  let text = '';
  let sending = false;
  let error = '';
  let shown = '';
  const keyOf = (p: {game:string,version:string}) => `${p.game}@${p.version}`;
  function later(): boolean {
    try { return sessionStorage.getItem('gamenight_playtest_later') === keyOf($playtestFeedback!); } catch { return false; }
  }
  $: if ($playtestFeedback && dialog && shown !== keyOf($playtestFeedback) && !later() && !document.querySelector('dialog[open]')) {
    shown = keyOf($playtestFeedback); rating = 0; text = ''; error = '';
    dialog.showModal();
  }
  function close() {
    try { if ($playtestFeedback) sessionStorage.setItem('gamenight_playtest_later', keyOf($playtestFeedback)); } catch {}
    dialog.close();
  }
  async function send(skip = false) {
    const p = $playtestFeedback; if (!p) return;
    sending = true; error = '';
    try {
      const session = await fetch('/auth/session', {cache: 'no-store'});
      if (!session.ok) throw Error('Please sign in again to send your answer.');
      const response = await fetch('/v1/rooms/playtest-feedback', {method: 'POST', headers: {'Content-Type': 'application/json', 'X-GameNight-CSRF': (await session.json()).csrf},
        body: JSON.stringify({game: p.game, version: p.version, rating: skip ? 0 : rating, text: skip ? '' : text.trim()}), signal: AbortSignal.timeout(10000)});
      if (!response.ok) throw Error(response.status === 403 ? 'This table moved on. Thanks anyway!' : 'Could not send your answer. Please try again.');
      playtestFeedback.set(null);
      dialog.close();
      if (!skip) window.showToast(`Thanks! The ${p.title} developer will read this.`);
    } catch (e) { error = e instanceof Error ? e.message : 'Could not send your answer.'; }
    finally { sending = false; }
  }
</script>
<dialog class="playtest-dialog" aria-labelledby="playtest-title" bind:this={dialog} oncancel={(event)=>{event.preventDefault(); if(!sending) close();}}>
  {#if $playtestFeedback}
  <form method="dialog" onsubmit={(event)=>{event.preventDefault(); send();}}>
    <p class="playtest-eyebrow">PLAYTEST · VERSION {$playtestFeedback.version}</p>
    <h2 id="playtest-title">How was {$playtestFeedback.title}?</h2>
    <p>You just played a test build. The developer reads every answer.</p>
    <div class="playtest-verdict" role="radiogroup" aria-label="Your verdict">
      <button type="button" role="radio" aria-checked={rating===1} class:chosen={rating===1} onclick={()=>rating=rating===1?0:1}><span aria-hidden="true">👍</span> Fun</button>
      <button type="button" role="radio" aria-checked={rating===-1} class:chosen={rating===-1} onclick={()=>rating=rating===-1?0:-1}><span aria-hidden="true">👎</span> Not yet</button>
    </div>
    <label for="playtest-text">What stood out? <span>Optional</span></label>
    <textarea id="playtest-text" rows="3" maxlength="1000" placeholder="What was fun, what was confusing, what broke…" bind:value={text}></textarea>
    {#if error}<p role="alert">{error}</p>{/if}
    <div class="playtest-actions">
      <button type="button" class="playtest-skip" disabled={sending} onclick={()=>send(true)}>Skip</button>
      <button type="submit" class="btn-primary" disabled={sending || (!rating && !text.trim())}>{sending?'Sending…':'Send'}</button>
    </div>
  </form>
  {/if}
</dialog>
