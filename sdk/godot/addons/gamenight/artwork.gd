extends Node
## Non-blocking catalog artwork, with bounded downloads and a small texture cache.
signal changed
const MAX_BYTES := 8 * 1024 * 1024
var cache: Dictionary = {}
var pending: Dictionary = {}
var waiting: Array[String] = []

static func remote_url(value: String) -> bool:
	return value.begins_with("https://") or value.begins_with("http://127.0.0.1:") or value.begins_with("http://localhost:")

func texture(value: String) -> Texture2D:
	if cache.has(value): return cache[value]
	if value.begins_with("data:image/") and value.length() <= MAX_BYTES:
		var result := decode(Marshalls.base64_to_raw(value.get_slice(",",1)))
		remember(value,result)
		return result
	if remote_url(value) and not pending.has(value) and not waiting.has(value):
		waiting.append(value)
		pump.call_deferred()
	return null

func remember(value: String, result: Texture2D) -> void:
	if cache.size() >= 32: cache.erase(cache.keys()[0])
	cache[value] = result

static func decode(body: PackedByteArray) -> Texture2D:
	if body.is_empty() or body.size() > MAX_BYTES: return null
	var image := Image.new()
	var error := ERR_FILE_UNRECOGNIZED
	if body.size()>8 and body[0]==137 and body[1]==80: error=image.load_png_from_buffer(body)
	elif body.size()>3 and body[0]==255 and body[1]==216: error=image.load_jpg_from_buffer(body)
	elif body.size()>12 and body.slice(0,4).get_string_from_ascii()=="RIFF": error=image.load_webp_from_buffer(body)
	if error != OK or image.get_width()>4096 or image.get_height()>4096: return null
	return ImageTexture.create_from_image(image)

func pump() -> void:
	while pending.size()<2 and not waiting.is_empty():
		var url: String = waiting.pop_front()
		var request := HTTPRequest.new()
		request.timeout = 8
		request.body_size_limit = MAX_BYTES
		request.max_redirects = 2
		add_child(request)
		pending[url] = request
		request.request_completed.connect(_completed.bind(url,request))
		if request.request(url) != OK:
			remember(url,null)
			pending.erase(url)
			request.queue_free()

func _completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, url: String, request: HTTPRequest) -> void:
	remember(url,decode(body) if result==HTTPRequest.RESULT_SUCCESS and code==200 else null)
	pending.erase(url)
	request.queue_free()
	changed.emit()
	pump.call_deferred()
