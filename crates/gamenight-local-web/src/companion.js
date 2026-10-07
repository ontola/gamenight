// GameNight phone screen SDK. Load it from a game's phone page:
//
//   <script src="/assets/companion.js"></script>
//   const game = GameNight.connect((data) => render(data));
//   game.send({ action: "roll" });
//
// Messages are plain JSON in both directions. The game sees which player sent
// each one; the page never needs to know. The connection comes back by itself
// when the game or the host restarts.
(function () {
  const params = new URLSearchParams(location.search);
  const profile = params.get("profile") || "";
  const game = params.get("game") || location.pathname.split("/")[2] || "";

  function connect(onMessage, onStatus) {
    let ws = null;
    let closed = false;
    let retry = 500;
    const queue = [];
    const status = (s) => onStatus && onStatus(s);

    function open() {
      const scheme = location.protocol === "https:" ? "wss:" : "ws:";
      const url = `${scheme}//${location.host}/api/companion/ws?profile=${encodeURIComponent(profile)}&game=${encodeURIComponent(game)}`;
      ws = new WebSocket(url);
      ws.onopen = () => {
        retry = 500;
        status("connected");
        while (queue.length) ws.send(queue.shift());
      };
      ws.onmessage = (event) => {
        let data;
        try {
          data = JSON.parse(event.data);
        } catch (_) {
          return;
        }
        onMessage(data);
      };
      ws.onclose = () => {
        if (closed) return;
        status("reconnecting");
        setTimeout(open, retry);
        retry = Math.min(retry * 2, 5000);
      };
    }
    open();

    return {
      send(data) {
        const text = JSON.stringify(data);
        if (ws && ws.readyState === WebSocket.OPEN) ws.send(text);
        else if (queue.length < 32) queue.push(text);
      },
      close() {
        closed = true;
        if (ws) ws.close();
      },
    };
  }

  window.GameNight = { connect, profile, game };
})();
