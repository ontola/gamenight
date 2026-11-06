using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace GameNightSdk
{
    /// <summary>
    /// The WebSocket to the GameNight host, on background threads. Messages wait
    /// in a queue until the main thread pumps them, so the connection keeps up
    /// while Unity's Time.timeScale is 0, the window is minimised or a frame
    /// takes long. Sends never block the caller.
    /// </summary>
    public sealed class Transport : IDisposable
    {
        const int MaxMessageBytes = 16 * 1024 * 1024;
        readonly ClientWebSocket _socket = new ClientWebSocket();
        readonly CancellationTokenSource _stop = new CancellationTokenSource();
        readonly BlockingCollection<string> _outbox = new BlockingCollection<string>(new ConcurrentQueue<string>());
        public readonly ConcurrentQueue<string> Inbox = new ConcurrentQueue<string>();
        volatile bool _open;
        volatile bool _closed;
        public string Failure;

        public bool IsOpen => _open && !_closed;
        /// <summary>True once the connection failed or ended. Make a new Transport to retry.</summary>
        public bool IsClosed => _closed;

        public Transport(string url)
        {
            Task.Run(() => Run(url));
        }

        public void Send(string text)
        {
            if (_closed) return;
            try { _outbox.Add(text); }
            catch (InvalidOperationException) { }
        }

        async Task Run(string url)
        {
            try
            {
                await _socket.ConnectAsync(new Uri(url), _stop.Token).ConfigureAwait(false);
                _open = true;
                var sender = Task.Run(SendLoop);
                await ReceiveLoop().ConfigureAwait(false);
                _outbox.CompleteAdding();
                await sender.ConfigureAwait(false);
            }
            catch (Exception e) when (e is WebSocketException || e is IOException || e is OperationCanceledException
                                      || e is ObjectDisposedException || e is InvalidOperationException
                                      || e is System.Net.Sockets.SocketException)
            {
                Failure = e.Message;
            }
            finally
            {
                _closed = true;
                _outbox.CompleteAdding();
            }
        }

        async Task ReceiveLoop()
        {
            var buffer = new byte[64 * 1024];
            var message = new MemoryStream();
            while (!_stop.IsCancellationRequested && _socket.State == WebSocketState.Open)
            {
                var result = await _socket.ReceiveAsync(new ArraySegment<byte>(buffer), _stop.Token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) break;
                message.Write(buffer, 0, result.Count);
                if (message.Length > MaxMessageBytes) throw new IOException("GameNight: message too large");
                if (!result.EndOfMessage) continue;
                Inbox.Enqueue(Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length));
                message.SetLength(0);
            }
        }

        async Task SendLoop()
        {
            try
            {
                foreach (var text in _outbox.GetConsumingEnumerable(_stop.Token))
                {
                    if (_socket.State != WebSocketState.Open) break;
                    var bytes = Encoding.UTF8.GetBytes(text);
                    await _socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, _stop.Token).ConfigureAwait(false);
                }
            }
            catch (Exception e) when (e is WebSocketException || e is OperationCanceledException || e is ObjectDisposedException || e is IOException)
            {
            }
        }

        public void Dispose()
        {
            _closed = true;
            try { _stop.Cancel(); } catch (ObjectDisposedException) { }
            try { _socket.Abort(); } catch (Exception) { }
            _socket.Dispose();
        }
    }
}
