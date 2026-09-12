const storage = window.gamenightStorage;
const localStorage = storage.local;
let initializing = true;

    // ---- Identity state -------------------------------------------------
    let profileId = localStorage.getItem('gamenight_profile_id')
      || ('prof_' + Math.random().toString(36).slice(2, 11));
    localStorage.setItem('gamenight_profile_id', profileId);

    // Set when this page was opened by scanning the QR above a character's
    // head: that body is already in the party, so the profile is applied to
    // it rather than adding a second, bodiless player.
    const params = new URLSearchParams(window.location.search);
    const claimPlayerId = params.get('claim');
    // Set when the wall QR was aimed at a seat by someone standing on the
    // sign-in pad. Preferred over a player id: seats survive a lobby restart.
    const claimSeat = params.get('seat');

    // The party member this profile is bound to when we weren't opened from
    // a character's QR — remembered from the first join so later saves
    // update that player instead of adding another one each time.
    let boundPlayerId = localStorage.getItem('gamenight_bound_player') || null;
    let currentArtworkId = localStorage.getItem('gamenight_current_artwork') || null;

    const GRID_SIZE = 48;

    // `null` means transparent. A face should be a *face* — filling the grid
    // with a background colour by default gives everyone an opaque tile with
    // a head buried in it, which is why the old sentinel-colour approach was
    // wrong in the first place.
    let gridData = Array(GRID_SIZE * GRID_SIZE).fill(null);
    const EMPTY = null;

    // Undo history. Bounded — this is a 48x48 grid on a phone, not Photoshop.
    const UNDO_LIMIT = 40;
    let undoStack = [];

    function pushUndo() {
      undoStack.push(gridData.slice());
      if (undoStack.length > UNDO_LIMIT) undoStack.shift();
      refreshUndoButton();
    }

    function undo() {
      const prev = undoStack.pop();
      if (!prev) return;
      gridData = prev;
      renderGrid();
      refreshUndoButton();
      onArtworkChanged();
    }

    function refreshUndoButton() {
      const b = document.getElementById('btn-undo');
      if (b) b.disabled = undoStack.length === 0;
    }

    const PALETTE = [
      '#ff5555', '#ffaa00', '#ffff55', '#55ff55', '#55ffff', '#5555ff', '#ff55ff',
      '#ffffff', '#c0c0c0', '#808080', '#404040', '#000000',
      '#8b4513', '#ffc0cb', '#7ddf64', '#c792ea'
    ];
    let currentColor = PALETTE[0];
    let currentTool = 'pencil';

    function renderPalette() {
      const el = document.getElementById('palette-swatches');
      el.innerHTML = '';
      PALETTE.forEach(col => {
        const sw = document.createElement('button');
        sw.type = 'button';
        sw.setAttribute('aria-label', col);
        sw.className = 'swatch' + (col === currentColor ? ' active' : '');
        sw.style.background = col;
        sw.onclick = () => { currentColor = col; setTool('pencil'); renderPalette(); };
        el.appendChild(sw);
      });
    }

    let showOutfitGuide = localStorage.getItem('gamenight_outfit_guide') !== 'false';
    let outfitGuidePixels = null, outfitGuideSprite = null, outfitGuideColor = null;
    function gridBackground(idx) {
      if (gridData[idx] !== EMPTY) return gridData[idx];
      return showOutfitGuide && outfitGuidePixels ? outfitGuidePixels[idx]
        : `linear-gradient(135deg, ${skinColor} 0 50%, #0f172a 50% 100%)`;
    }
    function toggleOutfitGuide() {
      showOutfitGuide = !showOutfitGuide;
      localStorage.setItem('gamenight_outfit_guide', String(showOutfitGuide));
      refreshOutfitGuide();
    }
    function refreshOutfitGuide() {
      const button = document.getElementById('outfit-guide-toggle');
      button.setAttribute('aria-pressed', String(showOutfitGuide));
      button.classList.toggle('active', showOutfitGuide);
      button.textContent = showOutfitGuide ? 'Hide outfit guide' : 'Show outfit guide';
      const cells = document.getElementById('pixel-grid').children;
      for (let i = 0; i < cells.length; i++) cells[i].style.background = gridBackground(i);
    }

    function renderGrid() {
      const container = document.getElementById('pixel-grid');
      container.innerHTML = '';
      gridData.forEach((color, idx) => {
        const div = document.createElement('div');
        div.className = 'pixel' + (color === EMPTY ? ' empty' : '');
        // Unpainted cells show the character colour, so the canvas previews
        // the head you're drawing on rather than a checkerboard. "Empty" and
        // "painted the same colour" looking identical is correct: in game
        // both come out as skin.
        div.style.background = gridBackground(idx);
        div.dataset.idx = idx;
        container.appendChild(div);
      });
      updatePreview();
    }

    // ---- Drawing: keep cells alive and only repaint changed pixels. ----
    let drawing = false, strokeDirty = false, activePointer = null;
    let brushSize = 1, lastPoint = null, strokeRect = null, previewFrame = null;
    function setBrushSize(size) {
      if (![1, 2, 4, 8].includes(size)) return;
      brushSize = size;
      document.querySelectorAll('[data-brush]').forEach(button => {
        const active = Number(button.dataset.brush) === size;
        button.classList.toggle('active', active);
        button.setAttribute('aria-pressed', String(active));
      });
    }
    function refreshPaintedPixel(idx) {
      const cell = document.getElementById('pixel-grid').children[idx];
      cell.style.background = gridBackground(idx);
      cell.classList.toggle('empty', gridData[idx] === EMPTY);
    }
    function putPixel(x, y, color) {
      if (x < 0 || y < 0 || x >= GRID_SIZE || y >= GRID_SIZE) return;
      const idx = y * GRID_SIZE + x;
      if (gridData[idx] === color) return;
      gridData[idx] = color;
      strokeDirty = true;
      refreshPaintedPixel(idx);
    }
    function stampBrush(x, y) {
      const offset = Math.floor((brushSize - 1) / 2);
      const color = currentTool === 'eraser' ? EMPTY : currentColor;
      for (let dy = 0; dy < brushSize; dy++)
        for (let dx = 0; dx < brushSize; dx++) putPixel(x + dx - offset, y + dy - offset, color);
    }
    function paintLine(from, to) {
      let [x, y] = from;
      const [endX, endY] = to;
      const dx = Math.abs(endX - x), dy = -Math.abs(endY - y);
      const sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1;
      let error = dx + dy;
      while (true) {
        stampBrush(x, y);
        if (x === endX && y === endY) break;
        const twice = error * 2;
        if (twice >= dy) { error += dy; x += sx; }
        if (twice <= dx) { error += dx; y += sy; }
      }
    }
    function paintAt(clientX, clientY) {
      const x = Math.floor((clientX - strokeRect.left) * GRID_SIZE / strokeRect.width);
      const y = Math.floor((clientY - strokeRect.top) * GRID_SIZE / strokeRect.height);
      if (x < 0 || y < 0 || x >= GRID_SIZE || y >= GRID_SIZE) { lastPoint = null; return; }
      if (currentTool === 'fill') {
        if (lastPoint) return;
        const before = gridData.slice();
        floodFill(y * GRID_SIZE + x, gridData[y * GRID_SIZE + x], currentColor);
        gridData.forEach((color, idx) => {
          if (color !== before[idx]) { strokeDirty = true; refreshPaintedPixel(idx); }
        });
      } else paintLine(lastPoint || [x, y], [x, y]);
      lastPoint = [x, y];
      // The stroke is already visible; render the two previews once per frame.
      if (previewFrame === null) previewFrame = requestAnimationFrame(() => {
        previewFrame = null;
        updatePreview();
      });
    }
    function bindCanvas() {
      const grid = document.getElementById('pixel-grid');
      grid.addEventListener('contextmenu', e => e.preventDefault());
      grid.addEventListener('pointerdown', e => {
        if (activePointer !== null || !e.isPrimary || e.button !== 0) return;
        e.preventDefault();
        activePointer = e.pointerId;
        drawing = true;
        strokeDirty = false;
        lastPoint = null;
        const rect = grid.getBoundingClientRect();
        strokeRect = {left: rect.left + grid.clientLeft, top: rect.top + grid.clientTop,
          width: grid.clientWidth, height: grid.clientHeight};
        pushUndo();
        grid.setPointerCapture(e.pointerId);
        paintAt(e.clientX, e.clientY);
      });
      grid.addEventListener('pointermove', e => {
        if (e.pointerId !== activePointer) return;
        e.preventDefault();
        const samples = e.getCoalescedEvents?.() || [];
        for (const sample of samples.length ? samples : [e]) paintAt(sample.clientX, sample.clientY);
      });
      const stop = e => {
        if (e.pointerId !== activePointer) return;
        if (e.type === 'pointerup') paintAt(e.clientX, e.clientY);
        drawing = false;
        activePointer = null;
        lastPoint = null;
        if (grid.hasPointerCapture(e.pointerId)) grid.releasePointerCapture(e.pointerId);
        if (!strokeDirty) { undoStack.pop(); refreshUndoButton(); }
        else onArtworkChanged();
      };
      grid.addEventListener('pointerup', stop);
      grid.addEventListener('pointercancel', stop);
      grid.addEventListener('lostpointercapture', stop);
    }

    function setTool(tool) {
      currentTool = tool;
      ['pencil', 'eraser', 'fill'].forEach(t => {
        const b = document.getElementById('tool-' + t);
        if (b) b.classList.toggle('active', t === tool);
      });
    }

    function floodFill(startIdx, targetColor, replacementColor) {
      if (targetColor === replacementColor) return;
      const queue = [startIdx];
      const visited = new Set();
      while (queue.length) {
        const curr = queue.pop();
        if (visited.has(curr) || curr < 0 || curr >= gridData.length) continue;
        visited.add(curr);
        if (gridData[curr] !== targetColor) continue;
        gridData[curr] = replacementColor;
        const r = Math.floor(curr / GRID_SIZE), c = curr % GRID_SIZE;
        if (r > 0) queue.push(curr - GRID_SIZE);
        if (r < GRID_SIZE - 1) queue.push(curr + GRID_SIZE);
        if (c > 0) queue.push(curr - 1);
        if (c < GRID_SIZE - 1) queue.push(curr + 1);
      }
    }

    function clearCanvas() {
      pushUndo();
      gridData = Array(GRID_SIZE * GRID_SIZE).fill(EMPTY);
      renderGrid();
      onArtworkChanged();
    }

    // ---- Faces ---------------------------------------------------------
    // Twelve starting faces, all drawn here from scratch. None of them are
    // derived from the lobby's old art: that art was CC BY-NC and cannot ship in a
    // commercial product, and a face you can recognise from the base game is
    // a worse starting point than one that's obviously yours to change.
    //
    // Each is features only, on a transparent background — the character's
    // colour shows through as skin. Painting a backdrop behind your face is a
    // habit worth not teaching.
    const INK = '#1a1a1a';
    const WHITE = '#ffffff';

    // Small drawing helpers, so a face is a recipe rather than 256 literals.
    function facePad() {
      const g = Array(16 * 16).fill(EMPTY);
      const put = (r, c, col) => {
        if (r >= 0 && r < 16 && c >= 0 && c < 16) g[r * 16 + c] = col;
      };
      const box = (r0, r1, c0, c1, col) => {
        for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) put(r, c, col);
      };
      const api = {
        g, put, box,
        // Round eye: white with a pupil looking slightly inward.
        eyesRound(row, ink = INK) {
          for (const c of [3, 9]) {
            box(row, row + 2, c, c + 3, WHITE);
            box(row + 1, row + 2, c + 1, c + 2, ink);
          }
          return api;
        },
        eyesDot(row, ink = INK) {
          box(row, row + 1, 4, 5, ink);
          box(row, row + 1, 10, 11, ink);
          return api;
        },
        eyesWide(row, ink = INK) {
          for (const c of [3, 9]) {
            box(row, row + 3, c, c + 3, WHITE);
            box(row + 1, row + 2, c + 1, c + 2, ink);
          }
          return api;
        },
        eyesClosed(row, ink = INK) {
          box(row + 1, row + 1, 3, 6, ink);
          box(row + 1, row + 1, 9, 12, ink);
          return api;
        },
        eyesSquare(row, col1 = '#5ce1ff', ink = INK) {
          for (const c of [3, 9]) {
            box(row, row + 3, c, c + 3, ink);
            box(row + 1, row + 2, c + 1, c + 2, col1);
          }
          return api;
        },
        wink(row, ink = INK) {
          box(row, row + 2, 3, 6, WHITE);
          box(row + 1, row + 2, 4, 5, ink);
          box(row + 1, row + 1, 9, 12, ink);   // the closed one
          return api;
        },
        brows(row, ink = INK, angry = true) {
          if (angry) {
            box(row, row, 3, 5, ink); put(row + 1, 6, ink);
            box(row, row, 10, 12, ink); put(row + 1, 9, ink);
          } else {
            box(row, row, 3, 6, ink);
            box(row, row, 9, 12, ink);
          }
          return api;
        },
        starEyes(row, col = '#ffe066') {
          for (const c of [4, 10]) {
            put(row, c, col);
            box(row + 1, row + 1, c - 1, c + 1, col);
            put(row + 2, c, col);
          }
          return api;
        },
        eyepatch(row, ink = INK) {
          box(row, row + 3, 9, 12, ink);
          box(row - 1, row - 1, 8, 13, ink);   // the strap
          box(row, row + 2, 3, 6, WHITE);
          box(row + 1, row + 2, 4, 5, ink);
          return api;
        },
        glasses(row, frame = '#4a5568') {
          box(row, row + 3, 2, 6, frame);
          box(row + 1, row + 2, 3, 5, WHITE);
          box(row, row + 3, 9, 13, frame);
          box(row + 1, row + 2, 10, 12, WHITE);
          box(row + 1, row + 1, 7, 8, frame);  // bridge
          return api;
        },
        mouthSmile(row, ink = INK) {
          box(row, row, 5, 10, ink);
          put(row - 1, 4, ink); put(row - 1, 11, ink);
          return api;
        },
        mouthGrin(row, ink = INK) {
          box(row, row + 2, 4, 11, ink);
          box(row + 1, row + 1, 5, 10, WHITE);   // teeth
          return api;
        },
        mouthOpen(row, ink = INK, inner = '#ff7a7a') {
          box(row, row + 2, 5, 10, ink);
          box(row + 1, row + 1, 6, 9, inner);
          return api;
        },
        mouthFrown(row, ink = INK) {
          box(row + 1, row + 1, 5, 10, ink);
          put(row, 4, ink); put(row, 11, ink);
          return api;
        },
        mouthLine(row, ink = INK) {
          box(row, row, 6, 9, ink);
          return api;
        },
        mouthTongue(row, ink = INK, tongue = '#ff6b9d') {
          box(row, row, 5, 10, ink);
          box(row + 1, row + 2, 7, 9, tongue);
          return api;
        },
        fangs(row, ink = INK) {
          box(row, row, 4, 11, ink);
          put(row + 1, 5, WHITE); put(row + 1, 10, WHITE);
          return api;
        },
        mouthGrid(row, ink = INK) {
          for (let c = 5; c <= 10; c += 2) box(row, row + 1, c, c, ink);
          box(row + 2, row + 2, 5, 10, ink);
          return api;
        },
        blush(row, col = '#ff8fa3') {
          box(row, row + 1, 1, 2, col);
          box(row, row + 1, 13, 14, col);
          return api;
        },
        freckles(row, col = '#b5651d') {
          for (const c of [2, 4, 11, 13]) { put(row, c, col); put(row + 1, c + 1, col); }
          return api;
        },
        antenna(col = '#9aa5b1', bulb = '#ff5555') {
          box(0, 2, 7, 8, col);
          put(0, 7, bulb); put(0, 8, bulb);
          return api;
        },
        moustache(row, col = '#5b3a1a') {
          box(row, row, 4, 11, col);
          put(row + 1, 4, col); put(row + 1, 11, col);
          return api;
        },
        done() { return normalizeFace(g); }
      };
      return api;
    }

    // Twelve recipes. Distinct silhouettes, not palette swaps of one design.
    const FACE_RECIPES = [
      { name: 'Happy',     build: () => facePad().eyesRound(5).mouthSmile(11).blush(9).done() },
      { name: 'Grin',      build: () => facePad().eyesRound(4).mouthGrin(10).done() },
      { name: 'Sleepy',    build: () => facePad().eyesClosed(6).mouthLine(11).blush(9).done() },
      { name: 'Grumpy',    build: () => facePad().brows(3).eyesDot(5).mouthFrown(11).done() },
      { name: 'Surprised', build: () => facePad().eyesWide(4).mouthOpen(10).done() },
      { name: 'Cheeky',    build: () => facePad().wink(5).mouthTongue(11).blush(9).done() },
      { name: 'Fangs',     build: () => facePad().eyesDot(5).fangs(11).brows(3, INK, true).done() },
      { name: 'Freckles',  build: () => facePad().eyesRound(5).freckles(9).mouthSmile(12).done() },
      { name: 'Pirate',    build: () => facePad().eyepatch(5).mouthGrin(11).done() },
      { name: 'Nerd',      build: () => facePad().glasses(4).mouthLine(11).freckles(9).done() },
      { name: 'Starry',    build: () => facePad().starEyes(5).mouthOpen(11).done() },
      { name: 'Robot',     build: () => facePad().antenna().eyesSquare(5).mouthGrid(11).done() },
    ];

    // Hair and headwear use the full native-pixel head canvas, independently
    // of the facial expression. Leave the eyes at their existing right offset.
    function dressRandomFace(face) {
      const pick = values => values[Math.floor(Math.random() * values.length)];
      const hair = pick(['#30231d', '#6b3926', '#c07832', '#efd078', '#dce3ef', '#8b4dcc']);
      const cloth = pick(['#d64c64', '#437bd1', '#7552b8', '#36a69a', '#e39a36']);
      const box = (x, y, w, h, color) => {
        for (let row = y; row < y + h; row++) for (let col = x; col < x + w; col++) {
          if (row >= 0 && row < GRID_SIZE && col >= 0 && col < GRID_SIZE) face[row * GRID_SIZE + col] = color;
        }
      };
      const styles = [
        () => { // Side part, with sideburns.
          box(12, 15, 25, 5, hair); box(16, 12, 17, 3, hair);
          box(12, 20, 5, 12, hair); box(17, 20, 9, 3, hair);
        },
        () => { // Curly hair: staggered little pixel curls.
          for (let x = 12; x < 36; x += 5) {
            box(x, 13 + (x % 2) * 2, 6, 6, hair); box(x + 1, 12 + (x % 2) * 2, 4, 8, hair);
          }
          box(11, 20, 5, 12, hair);
        },
        () => { // Mohawk.
          box(22, 7, 5, 14, hair); box(24, 5, 4, 13, hair);
          box(20, 17, 10, 4, hair);
        },
        () => { // Long hair, keeping the face open.
          box(13, 14, 24, 6, hair); box(11, 20, 7, 20, hair);
          box(18, 19, 7, 4, hair);
        },
        () => { // Beanie and pompom.
          box(13, 13, 24, 8, cloth); box(17, 10, 16, 3, cloth);
          box(23, 6, 6, 4, WHITE); box(11, 21, 28, 3, WHITE);
        },
        () => { // Baseball cap with a right-facing brim.
          box(14, 14, 22, 7, cloth); box(18, 11, 14, 3, cloth);
          box(12, 21, 31, 3, cloth); box(27, 15, 3, 4, WHITE);
        },
        () => { // Wizard hat.
          for (let y = 5; y < 22; y++) {
            const width = 3 + Math.floor((y - 5) / 2) * 2;
            box(25 - Math.floor(width / 2), y, width, 1, cloth);
          }
          box(11, 22, 30, 3, cloth); box(24, 14, 2, 3, '#ffe066');
        },
        () => { // Crown.
          box(13, 17, 25, 6, '#efc448');
          for (const x of [13, 23, 34]) box(x, 11, 4, 6, '#efc448');
          box(23, 19, 4, 3, cloth);
        },
      ];
      pick(styles)();
      return face;
    }

    // Never hand out the same face twice running: pressing 🎲 and getting no
    // visible change reads as a broken button rather than bad luck.
    let lastFaceIdx = -1;
    function randomFace() {
      let i = Math.floor(Math.random() * FACE_RECIPES.length);
      if (FACE_RECIPES.length > 1 && i === lastFaceIdx) {
        i = (i + 1 + Math.floor(Math.random() * (FACE_RECIPES.length - 1)))
            % FACE_RECIPES.length;
      }
      lastFaceIdx = i;
      return dressRandomFace(FACE_RECIPES[i].build());
    }

    function loadPreset() {
      pushUndo();
      gridData = randomFace();
      renderGrid();
      onArtworkChanged();
    }

    // ---- Preview -------------------------------------------------------
    // Preview uses the same body atlas and profile tint as the lobby.
    // The character's own colour: skin, and therefore the backdrop your face
    // is drawn on. One deliberate choice rather than something inferred from
    // the art — deriving it meant recolouring your character by accident
    // every time you changed the drawing.
    const CHARACTER_COLORS = [
      '#ff5555', '#ff8f3f', '#ffc94a', '#7ddf64', '#3fd0c9',
      '#55a0ff', '#8b7bff', '#c792ea', '#ff7ab8', '#b0764a',
      '#9aa5b1', '#4a5568'
    ];
    let characterColor = localStorage.getItem('gamenight_character_color')
      || CHARACTER_COLORS[Math.floor(Math.random() * CHARACTER_COLORS.length)];

    const SKIN_COLORS = ['#f5e9be', '#f2cfad', '#dfa67f', '#bc805b', '#925c3b', '#633d2b', '#ffb7c5', '#8dcdaa', '#9ebfee', '#bba2d9'];
    let skinColor = localStorage.getItem('gamenight_skin_color') || '#f5e9be';
    function setSkinColor(col) {
      skinColor = col;
      localStorage.setItem('gamenight_skin_color', col);
      renderSkinColors();
      updatePreview();
      renderGrid();
      scheduleSave();
    }
    function renderSkinColors() {
      const el = document.getElementById('skin-colors');
      el.replaceChildren();
      SKIN_COLORS.forEach(col => {
        const sw = document.createElement('button');
        sw.type = 'button'; sw.setAttribute('aria-label', col);
        sw.setAttribute('aria-pressed', String(col === skinColor));
        sw.className = 'swatch' + (col === skinColor ? ' active' : '');
        sw.style.background = col; sw.onclick = () => setSkinColor(col);
        el.appendChild(sw);
      });
    }
    // Semantic skin pixels are the two cream shades in the base atlas.
    // Paint is composited afterwards and never recoloured.
    function colourBodyPixels(rgba, clothing, skin) {
      const rgb = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
      const clothes = rgb(clothing), flesh = rgb(skin);
      for (let i = 0; i < rgba.length; i += 4) {
        if (!rgba[i + 3]) continue;
        const isSkin = rgba[i] > 200 && rgba[i + 1] > 170 && rgba[i + 2] < rgba[i + 1];
        const shade = isSkin ? rgba[i] / 245 : Math.max(rgba[i], rgba[i + 1], rgba[i + 2]) / 255;
        const colour = isSkin ? flesh : clothes;
        for (let c = 0; c < 3; c++) rgba[i + c] = Math.min(255, Math.round(colour[c] * shade));
      }
      return rgba;
    }

    function setCharacterColor(col) {
      characterColor = col;
      localStorage.setItem('gamenight_character_color', col);
      renderCharacterColors();
      updatePreview();
    }

    function renderCharacterColors() {
      const el = document.getElementById('character-colors');
      if (!el) return;
      el.innerHTML = '';
      CHARACTER_COLORS.forEach(col => {
        const sw = document.createElement('button');
        sw.type = 'button';
        sw.setAttribute('aria-label', col);
        sw.className = 'swatch' + (col === characterColor ? ' active' : '');
        sw.style.background = col;
        sw.onclick = () => setCharacterColor(col);
        el.appendChild(sw);
      });
    }

    // the lobby's face layer is a 46x32 tile, and the drawn avatar is rendered
    // into a 48x48 square of it (`AVATAR_FACE_SIZE` in gamenight.rs). This
    // shows that tile at actual proportions, so it's obvious how much of the
    // head is yours and how much is skin.
    const FACE_TILE_W = 46, FACE_TILE_H = 32, FACE_ART = GRID_SIZE;

    // Every editor pixel maps to exactly one sprite pixel, with a larger grid
    // for glasses and beards rather than enlarged pixels.
    function drawPixelFace(ctx, x, y) {
      gridData.forEach((col, i) => {
        if (col === EMPTY) return;
        ctx.fillStyle = col;
        ctx.fillRect(x + i % GRID_SIZE, y + Math.floor(i / GRID_SIZE), 1, 1);
      });
    }

    let previewSprite = null;
    let previewRequest = 0;
    const previewTint = document.createElement('canvas');
    previewTint.width = 96;
    previewTint.height = 80;

    function loadPreviewSprite() {
      const request = ++previewRequest;
      const img = new Image();
      const status = document.getElementById('preview-status');
      status.textContent = 'Loading outfit…';
      img.onload = () => {
        if (request !== previewRequest) return;
        previewSprite = img;
        status.textContent = '';
        updatePreview();
      };
      img.onerror = () => {
        if (request === previewRequest) status.textContent = 'Could not load outfit. Try again.';
      };
      img.src = '/assets/characters/' + 'living-room';
    }

    function updatePreview() {
      const cvs = document.getElementById('preview-canvas');
      if (!cvs) return;
      const ctx = cvs.getContext('2d');
      ctx.clearRect(0, 0, cvs.width, cvs.height);
      ctx.imageSmoothingEnabled = false;
      if (previewSprite) {
        // Recolour clothing and skin independently in the native-pixel idle cell.
        const tint = previewTint.getContext('2d');
        tint.globalCompositeOperation = 'source-over';
        tint.clearRect(0, 0, 96, 80);
        tint.drawImage(previewSprite, 0, 0, 96, 80, 0, 0, 96, 80);
        const bodyPixels = tint.getImageData(0, 0, 96, 80);
        colourBodyPixels(bodyPixels.data, characterColor, skinColor);
        tint.putImageData(bodyPixels, 0, 0);
        ctx.drawImage(previewTint, 0, 0);
        // Exactly the same 48×48 crop that receives the face drawing.
        // Reference pixels are display-only and never copied into gridData.
        if (outfitGuideSprite !== previewSprite || outfitGuideColor !== characterColor + skinColor) {
          const rgba = tint.getImageData(24, 4, GRID_SIZE, GRID_SIZE).data;
          outfitGuidePixels = Array.from({length: GRID_SIZE * GRID_SIZE}, (_, i) =>
            `rgba(${rgba[i*4]},${rgba[i*4+1]},${rgba[i*4+2]},${rgba[i*4+3]/255})`);
          outfitGuideSprite = previewSprite;
          outfitGuideColor = characterColor + skinColor;
          refreshOutfitGuide();
        }
        // Paint stays above the skin without being tinted.
        // Keep the face centre while leaving a larger area for accessories.
        drawPixelFace(ctx, 24, 4);
      }

    }

    // ---- Names ---------------------------------------------------------
    const FUN_NAMES = ['Falcon','Panda','Mango','Rocket','Disco','Waffle','Ninja','Pickle',
                       'Comet','Biscuit','Tiger','Noodle'];
    function randomName() {
      return FUN_NAMES[Math.floor(Math.random() * FUN_NAMES.length)];
    }
    // ---- Avatar wire format --------------------------------------------
    // Matches crates/gamenight-protocol/src/avatar.rs. `null` is
    // transparent, explicitly — no magic background colour.
    function encodeAvatar(grid) {
      return JSON.stringify({ v: 1, w: GRID_SIZE, h: GRID_SIZE, px: grid });
    }

    // Centre old drawings without stretching or losing any source pixels.
    function normalizeFace(pixels, width = Math.sqrt(pixels?.length || 0), height = width) {
      if (!Array.isArray(pixels) || !Number.isInteger(width) || !Number.isInteger(height)
          || width < 1 || height < 1 || width > GRID_SIZE || height > GRID_SIZE
          || pixels.length !== width * height) return null;
      const result = Array(GRID_SIZE * GRID_SIZE).fill(EMPTY);
      // Old 32px canvas began at atlas (38,19); the head canvas begins at (24,4).
      // Preserve the drawing on the character, not at the centre of the new box.
      const ox = width === 32 ? 14 : width === 16 ? 22 : Math.floor((GRID_SIZE - width) / 2);
      const oy = height === 32 ? 15 : height === 16 ? 23 : Math.floor((GRID_SIZE - height) / 2);
      pixels.forEach((color, i) => {
        result[(oy + Math.floor(i / width)) * GRID_SIZE + ox + i % width] = color ?? EMPTY;
      });
      return result;
    }

    function decodeAvatar(text) {
      try {
        const o = JSON.parse(text);
        if (Array.isArray(o)) return normalizeFace(o.map(c => c === '#0f172a' ? EMPTY : c));
        if (o?.v === 1) return normalizeFace(o.px, o.w, o.h);
      } catch (_) {}
      return null;
    }

    async function init() {
      loadPreviewSprite();
      refreshOutfitGuide();
      renderCharacterColors();
      renderSkinColors();
      renderGrid();
      renderPalette();
      bindCanvas();
      refreshUndoButton();

      const nameEl = document.getElementById('player-name');
      nameEl.addEventListener('input', scheduleSave);
      document.getElementById('name-edit').onclick = () => {
        nameEl.focus();
        nameEl.select();
      };
      document.getElementById('name-dice').onclick = () => {
        nameEl.value = randomName();
        scheduleSave();
      };

      if (storage.cloud) {
        document.querySelector('.nav-tabs').hidden=true;
        const initial=storage.initial;
        if(initial.workspace && !storage.pending){
          const saved=validateBackup(initial.workspace);
          localStorage.setItem('gamenight_artworks',JSON.stringify(saved.artworks));
          localStorage.setItem('gamenight_current_artwork',saved.activeArtworkId);
          currentArtworkId=saved.activeArtworkId;
        }
        if (!storage.pending) {
          localStorage.setItem('gamenight_player_name',initial.profile.display_name);
          skinColor=initial.profile.skin_color;
        }
      }
      await loadProfileData();
      initializing = false;
      if(storage.cloud)status(storage.pending?'Local changes need attention. Export before refreshing if another device edited your profile.':'Saved to your GameNight account', storage.pending?'#fbbf24':undefined);
    }

    let playlistView = null;
    let playlistBusy = false;
    let playlistLoading = false;
    let draggedEntry = null;

    function switchTab(tab) {
      document.querySelectorAll('.tab-content').forEach(el => el.classList.toggle('active', el.id === 'tab-' + tab));
      document.querySelectorAll('.nav-tabs .nav-btn').forEach(el => el.classList.toggle('active', el.textContent.toLowerCase() === tab));
      if (tab === 'playlist') loadPlaylist();
      if (tab === 'session') loadSession();
    }

    let sessionLoading = false;
    async function loadSession() {
      if (sessionLoading) return;
      sessionLoading = true;
      try {
        const response = await fetch('/api/profiles/' + encodeURIComponent(profileId) + '/session', { cache: 'no-store', signal: AbortSignal.timeout(10000) });
        if (!response.ok) throw new Error('GameNight is unavailable. Your saved character is still on this phone.');
        const session = await response.json();
        document.getElementById('session-link-status').textContent = session.linked ? `Signed in as ${session.player_name}` : 'Not linked to a controller';
        document.getElementById('session-link-help').textContent = session.linked ? `${session.seat === null ? "Your profile is linked to this party." : "Player " + (session.seat + 1) + "."} Edit your name and character in the Character tab. To disconnect, choose Unlink in your controller’s Start menu.` : 'Press Start on your controller in the lobby, then scan the QR shown in your player menu.';
        document.getElementById('session-player-count').textContent = session.players;
        document.getElementById('session-current-game').textContent = session.current ? `${session.current.title} · ${session.current.phase}` : 'In the lobby';
        document.getElementById('session-next-game').textContent = session.next || 'No game queued';
      } catch (error) {
        document.getElementById('session-link-status').textContent = error.message;
        document.getElementById('session-link-help').textContent = 'Reconnect to the same network as GameNight and try again.';
        ['session-player-count', 'session-current-game', 'session-next-game'].forEach(id => document.getElementById(id).textContent = '—');
      } finally { sessionLoading = false; }
    }
    async function loadPlaylist() {
      if (playlistBusy || playlistLoading || draggedEntry !== null) return;
      playlistLoading = true;
      try {
        const response = await fetch('/api/playlist', { cache: 'no-store', signal: AbortSignal.timeout(10000) });
        if (!response.ok) throw new Error('Playlist unavailable. Check that GameNight is running, then refresh.');
        const view = await response.json();
        if (JSON.stringify(view) !== JSON.stringify(playlistView)) {
          playlistView = view;
          renderPlaylist();
        }
        document.getElementById('playlist-status').textContent = view.playlist.entries.length ? '' : 'No games queued yet.';
      } catch (error) {
        document.getElementById('playlist-status').textContent = error.message;
      } finally { playlistLoading = false; }
    }

    function renderPlaylist(focusIndex) {
      const list = document.getElementById('playlist-list');
      list.replaceChildren();
      playlistView.playlist.entries.forEach((entry, index, entries) => {
        const row = document.createElement('li');
        row.className = 'playlist-row';
        row.dataset.index = index;
        const handle = document.createElement('button');
        handle.type = 'button';
        handle.className = 'drag-handle';
        handle.textContent = '⠿';
        handle.setAttribute('aria-label', `Drag ${entry.title} to reorder`);
        handle.disabled = playlistBusy;
        row.append(handle);
        const title = document.createElement('div');
        title.className = 'playlist-title';
        title.textContent = entry.title;
        const badge = document.createElement('small');
        badge.textContent = [playlistView.playlist.current === index ? 'Playing' : '', playlistView.next === entry.game ? 'Up next' : ''].filter(Boolean).join(' · ');
        title.append(badge);
        row.append(title);
        [-1, 1].forEach(direction => {
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = direction < 0 ? '↑' : '↓';
          button.setAttribute('aria-label', `Move ${entry.title} ${direction < 0 ? 'up' : 'down'}`);
          button.disabled = playlistBusy || index + direction < 0 || index + direction >= entries.length;
          button.onclick = () => movePlaylistEntry(index, index + direction);
          row.append(button);
        });
        const next = document.createElement('button');
        next.type = 'button'; next.textContent = '⇈';
        next.title = 'Play this next';
        next.setAttribute('aria-label', `Play ${entry.title} next`);
        const current = playlistView.playlist.current;
        const nextIndex = current == null ? 0 : (current + 1) % entries.length;
        next.disabled = playlistBusy || index === current || index === nextIndex;
        next.onclick = () => {
          const target = current == null ? 0 : current + 1 - (index < current ? 1 : 0);
          movePlaylistEntry(index, target);
        };
        row.append(next);
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'remove-entry';
        remove.textContent = '×';
        remove.setAttribute('aria-label', `Remove ${entry.title} from playlist`);
        remove.disabled = playlistBusy;
        remove.onclick = () => updatePlaylist({ from: index, remove: true }, index);
        row.append(remove);
        handle.onpointerdown = event => {
          if (playlistBusy || playlistLoading || draggedEntry !== null || event.button !== 0) return;
          event.preventDefault();
          draggedEntry = index;
          let target = index;
          let lastY = event.clientY;
          row.classList.add('dragging');
          handle.setPointerCapture(event.pointerId);
          const locate = y => {
            const rows = [...list.children];
            target = rows.findIndex(el => y < el.getBoundingClientRect().bottom);
            if (target < 0) target = rows.length - 1;
            rows.forEach((el, i) => el.classList.toggle('drag-over', i === target && target !== index));
          };
          // Keep long queues movable beyond the visible phone viewport.
          const scrolling = setInterval(() => {
            const delta = lastY < 80 ? -12 : lastY > innerHeight - 80 ? 12 : 0;
            if (delta) { window.scrollBy(0, delta); locate(lastY); }
          }, 30);
          handle.onpointermove = event => { lastY = event.clientY; locate(lastY); };
          const finish = cancelled => {
            clearInterval(scrolling);
            handle.onpointermove = null;
            handle.onpointerup = null;
            handle.onpointercancel = null;
            handle.onlostpointercapture = null;
            draggedEntry = null;
            row.classList.remove('dragging');
            [...list.children].forEach(el => el.classList.remove('drag-over'));
            if (!cancelled && target !== index) movePlaylistEntry(index, target);
          };
          handle.onpointerup = () => finish(false);
          handle.onpointercancel = () => finish(true);
          handle.onlostpointercapture = () => finish(true);
        };
        list.append(row);
      });
      if (focusIndex !== undefined) list.children[focusIndex]?.querySelector('button:not(:disabled)')?.focus();
    }

    async function movePlaylistEntry(from, to) {
      if (from === to) return;
      return updatePlaylist({ from, to }, to);
    }

    async function updatePlaylist(change, focusIndex) {
      if (playlistBusy || playlistLoading || draggedEntry !== null) return;
      playlistBusy = true;
      renderPlaylist();
      const status = document.getElementById('playlist-status');
      status.textContent = change.remove ? 'Removing game…' : 'Saving order…';
      try {
        const response = await fetch('/api/playlist', {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(10000),
          body: JSON.stringify({ expected: playlistView.playlist, ...change })
        });
        if (!response.ok) throw new Error(response.status === 409 ? 'The playlist changed on another screen. Refresh and try again.' : 'Could not save the order. Refresh and try again.');
        playlistView = await response.json();
        status.textContent = 'Playlist updated.';
      } catch (error) { status.textContent = error.message; }
      finally { playlistBusy = false; renderPlaylist(focusIndex); }
    }
    setInterval(() => {
      if (!document.hidden && document.getElementById('tab-playlist').classList.contains('active')) loadPlaylist();
      if (!document.hidden && document.getElementById('tab-session').classList.contains('active')) loadSession();
    }, 4000);


    async function loadProfileData() {
      let savedAvatar = null;
      let cachedProfile = null;
      try { cachedProfile = JSON.parse(localStorage.getItem('gamenight_saved_profile')); } catch (_) {}
      document.getElementById('player-name').value = localStorage.getItem('gamenight_player_name') || cachedProfile?.username || randomName();
      try {
        const prof = await storage.loadProfile(profileId);
        if (prof) {
          document.getElementById('player-name').value = localStorage.getItem('gamenight_player_name') || cachedProfile?.username || prof.username || randomName();
          if (prof.skin_color) {
            skinColor = prof.skin_color;
            localStorage.setItem('gamenight_skin_color', prof.skin_color);
            renderCharacterColors();
      renderSkinColors();
          }
          if (prof.avatar) savedAvatar = decodeAvatar(prof.avatar);
        } else {
          // Not signed in / no profile yet: give them an identity rather
          // than an empty field to stare at.
          document.getElementById('player-name').value = localStorage.getItem('gamenight_player_name') || cachedProfile?.username || randomName();
        }
      } catch (e) {
      }

      // Start from something drawable. An empty grid is a blank stare; a
      // ready-made head gives you a shape to push around.
      let list = loadArtworks();
      if (!list.length) {
        newArtwork(savedAvatar || randomFace(), 'My face');
        return;
      }
      if (!currentArtworkId || !list.find(a => a.id === currentArtworkId)) {
        currentArtworkId = list[0].id;
      }
      selectArtwork(currentArtworkId);
    }

    // ---- Auto-save ------------------------------------------------------
    // Every edit is pushed through on its own; there is no save button. Edits
    // are debounced so dragging the pencil across the grid is one request at
    // the end of the stroke rather than one per pixel.
    let saveTimer = null;
    let savingNow = false;
    let savePending = false;

    function showBlocked(title, line1, line2) {
      let el = document.getElementById('blocked-banner');
      if (!el) {
        el = document.createElement('div');
        el.id = 'blocked-banner';
        el.className = 'blocked';
        document.querySelector('main').prepend(el);
      }
      el.innerHTML = '';
      const h = document.createElement('div');
      h.className = 'blocked-title';
      h.innerText = '⚠️ ' + title;
      const p1 = document.createElement('div');
      p1.innerText = line1;
      const p2 = document.createElement('div');
      p2.className = 'blocked-hint';
      p2.innerText = line2;
      el.append(h, p1, p2);
      el.style.display = 'block';
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      status('');
    }

    function hideBlocked() {
      const el = document.getElementById('blocked-banner');
      if (el) el.style.display = 'none';
    }

    function status(msg, colour) {
      const el = document.getElementById('status-msg');
      el.innerText = msg;
      el.style.color = colour || '#34d399';
    }

    function scheduleSave() {
      if(storage.cloud && initializing) return;
      const name = document.getElementById('player-name').value;
      if (name.trim()) localStorage.setItem('gamenight_player_name', name);

      clearTimeout(saveTimer);
      status('Saving…', '#94a3b8');
      saveTimer = setTimeout(() => { pushProfile(); }, 400);
    }

    async function pushProfile() {
      // Collapse overlapping saves: a request already in flight means this
      // one can wait and pick up the newest state when that finishes.
      if (savingNow) { savePending = true; return; }
      savingNow = true;
      try {
        const prof = {
          id: profileId,
          username: document.getElementById('player-name').value,
          skin_color: skinColor,
          avatar: encodeAvatar(gridData),
        };
        localStorage.setItem('gamenight_saved_profile', JSON.stringify(prof));
        await storage.save(prof, buildBackup());
        if(storage.cloud){status('Saved to your GameNight account');return;}

        // Push straight through to the party. `claim` is whichever player
        // this profile is bound to — the character whose QR was scanned, or
        // the one our first join created. Sending it makes every later save
        // an update rather than a second JoinParty.
        const target = claimPlayerId || boundPlayerId;
        const join = await fetch('/api/profiles/' + profileId + '/join', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            claim: target,
            seat: claimSeat === null ? null : Number(claimSeat),
            link_revision: Number(params.get('link_revision') || 0)
          })
        });
        if (join.ok) {
          const data = await join.json();
          if (data.status === 'unlinked') {
            showBlocked("Controller unlinked", data.message, "Your saved character is still on this phone.");
            status("Saved on your phone", "#94a3b8");
            return;
          }
          if (data.status === 'no_such_seat') {
            status('⚠️ ' + data.message, '#fbbf24');
            return;
          }
          if (data.status === 'already_signed_in') {
            // A dead end until they do something about it, so it gets a
            // banner rather than a line of status text that scrolls past.
            showBlocked(
              "You're already signed in",
              data.seat === null || data.seat === undefined
                ? 'This phone is already playing as another character.'
                : ('This phone is already playing as the character on seat '
                   + (data.seat + 1) + '.'),
              'Leave that character first, or use a different phone.'
            );
            return;
          }
          hideBlocked();
          if (!boundPlayerId && data.player_id) {
            boundPlayerId = data.player_id;
            localStorage.setItem('gamenight_bound_player', boundPlayerId);
          }
          status(target ? '✓ Synced to your character' : '✓ Joined the party');
        } else {
          status(storage.cloud ? e.message : '⚠️ Saved locally — is the daemon running?', '#fbbf24');
        }
      } catch (e) {
        status(storage.cloud ? e.message : '⚠️ Saved locally — is the daemon running?', '#fbbf24');
      } finally {
        savingNow = false;
        if (savePending) { savePending = false; pushProfile(); }
      }
    }

    // Portable backups contain artwork and preferences, never controller/session claims.
    function backupMessage(message) { document.getElementById('backup-status').textContent = message; }
    async function downloadFile(blob, filename) {
      const file = new File([blob], filename, {type:blob.type});
      if (navigator.canShare?.({files:[file]})) {
        try {
          await navigator.share({files:[file], title:'GameNight backup'});
          backupMessage('File shared. Keep the saved copy to restore your data.');
          return;
        } catch (error) {
          if (error.name === 'AbortError') { backupMessage('Sharing cancelled. Your faces are still saved here.'); return; }
        }
      }
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url; link.download = filename;
      document.body.appendChild(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
      backupMessage('Download requested. If your phone blocks it, use “Copy backup instead” below.');
    }
    // v2: palette index 0 is transparent; runs are [length, paletteIndex].
    // One palette is shared across every face in the backup.
    function encodeCompactBackup(backup) {
      const palette = [], indexes = new Map();
      const artworks = backup.artworks.map(({data, ...art}) => {
        const runs = [];
        for (const pixel of data) {
          let index = 0;
          if (pixel !== null) {
            const color = pixel.toLowerCase();
            if (!indexes.has(color)) { palette.push(color); indexes.set(color, palette.length); }
            index = indexes.get(color);
          }
          if (runs.length && runs[runs.length - 1] === index) runs[runs.length - 2]++;
          else runs.push(1, index);
        }
        return {...art, runs};
      });
      return {...backup, version:2, palette, artworks};
    }
    function buildBackup() {
      const artworks = loadArtworks().map(a => ({id:a.id, name:a.name,
        data:a.id === currentArtworkId ? gridData.slice() : a.data}));
      return JSON.stringify(encodeCompactBackup({format:'gamenight-character-backup',
        exportedAt:new Date().toISOString(), gridSize:GRID_SIZE,
        username:document.getElementById('player-name').value,
        skinColor, activeArtworkId:currentArtworkId, artworks}));
    }
    async function copyBackup() {
      const text = buildBackup();
      const field = document.getElementById('backup-text');
      document.getElementById('backup-text-panel').open = true;
      field.value = text;
      try {
        await navigator.clipboard.writeText(text);
        backupMessage('Backup copied. Paste it into a note or document to keep it.');
      } catch (_) {
        field.focus(); field.select(); field.setSelectionRange(0, text.length);
        backupMessage('Select and copy the complete text below, then save it in a note.');
      }
    }
    function exportBackup() {
      const text = buildBackup();
      document.getElementById('backup-text').value = text;
      document.getElementById('backup-text-panel').open = true;
      // Plain text is supported by more Android share targets; its contents
      // remain the same versioned JSON accepted by the restore flow.
      downloadFile(new Blob([text], {type:'text/plain'}),
        'gamenight-faces-' + new Date().toISOString().slice(0,10) + '.txt');
    }
    function exportFacePng() {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = GRID_SIZE;
      const ctx = canvas.getContext('2d');
      gridData.forEach((color, i) => {
        if (color === EMPTY) return;
        ctx.fillStyle = color; ctx.fillRect(i % GRID_SIZE, Math.floor(i / GRID_SIZE), 1, 1);
      });
      canvas.toBlob(blob => {
        if (!blob) { backupMessage('Could not create the PNG. Please try again.'); return; }
        downloadFile(blob, 'gamenight-face.png');

      }, 'image/png');
    }
    function validateBackup(value) {
      const color = c => typeof c === 'string' && /^#[0-9a-f]{6}$/i.test(c);
      if (!value || value.format !== 'gamenight-character-backup' || value.version !== 2
          || value.gridSize !== GRID_SIZE || !Array.isArray(value.palette)
          || value.palette.length > 200 * GRID_SIZE ** 2 || !value.palette.every(color)
          || !Array.isArray(value.artworks) || !value.artworks.length || value.artworks.length > 200
          || typeof value.username !== 'string' || value.username.length > 100 || !color(value.skinColor))
        throw Error('Please import a current compact GameNight backup.');
      const cells = GRID_SIZE ** 2, ids = new Set();
      const artworks = value.artworks.map(art => {
        if (!art || typeof art.id !== 'string' || art.id.length > 200 || ids.has(art.id)
            || typeof art.name !== 'string' || art.name.length > 200
            || !Array.isArray(art.runs) || !art.runs.length
            || art.runs.length % 2 || art.runs.length > cells * 2)
          throw Error('Invalid artwork. Nothing was imported.');
        ids.add(art.id);
        const data = [];
        for (let i = 0; i < art.runs.length; i += 2) {
          const length = art.runs[i], index = art.runs[i + 1];
          if (!Number.isInteger(length) || length < 1 || data.length + length > cells
              || !Number.isInteger(index) || index < 0 || index > value.palette.length)
            throw Error('Invalid pixel runs. Nothing was imported.');
          const pixel = index === 0 ? null : value.palette[index - 1];
          for (let j = 0; j < length; j++) data.push(pixel);
        }
        if (data.length !== cells) throw Error('Incomplete artwork. Nothing was imported.');
        return {id:art.id, name:art.name, data};
      });
      return {...value, artworks};
    }
    async function importBackup(input) {
      const file = input.files?.[0];
      if (!file) return;
      try {
        if (file.size > 5 * 1024 * 1024) throw Error('Backup is too large (maximum 5 MB).');
        const backup = validateBackup(JSON.parse(await file.text()));
        const merged = loadArtworks();
        let active = currentArtworkId, added = 0;
        for (const incoming of backup.artworks) {
          const same = merged.find(a => a.name === incoming.name && JSON.stringify(a.data) === JSON.stringify(incoming.data));
          let id = same?.id;
          if (!same) {
            id = 'art_' + (globalThis.crypto?.randomUUID?.() || (Date.now() + '_' + Math.random().toString(36).slice(2)));
            merged.push({...incoming, id}); added++;
          }
          if (incoming.id === backup.activeArtworkId) active = id;
        }
        active = merged.some(a => a.id === active) ? active : merged[0].id;
        const values = {gamenight_artworks:JSON.stringify(merged), gamenight_current_artwork:active,
          gamenight_player_name:backup.username, gamenight_skin_color:backup.skinColor};
        const previous = Object.fromEntries(Object.keys(values).map(k => [k, localStorage.getItem(k)]));
        try { for (const [key,value] of Object.entries(values)) localStorage.setItem(key,value); }
        catch (error) {
          for (const [key,value] of Object.entries(previous)) {
            if (value === null) localStorage.removeItem(key); else localStorage.setItem(key,value);
          }
          throw Error('Not enough browser storage. Existing faces were kept.');
        }
        skinColor = backup.skinColor;
        document.getElementById('player-name').value = backup.username;
        undoStack = []; refreshUndoButton(); renderCharacterColors(); selectArtwork(active);
        backupMessage(`Imported ${added} face${added === 1 ? '' : 's'}. Existing faces were kept.`);
      } catch (error) { backupMessage(error instanceof SyntaxError ? 'Invalid JSON file. Nothing was imported.' : error.message); }
      finally { input.value = ''; }
    }

    // ---- Artwork gallery ------------------------------------------------
    // A list of saved pieces, so experimenting never costs you the last one.
    function loadArtworks() {
      try {
        const list = JSON.parse(localStorage.getItem('gamenight_artworks') || '[]');
        return Array.isArray(list) ? list.map(a => ({...a, data: normalizeFace(a.data)})).filter(a => a.data) : [];
      } catch (e) { return []; }
    }

    function saveArtworks(list) {
      localStorage.setItem('gamenight_artworks', JSON.stringify(list));
    }

    /// Write the live grid back into the artwork it came from, then save.
    function onArtworkChanged() {
      const list = loadArtworks();
      const cur = list.find(a => a.id === currentArtworkId);
      if (cur) {
        cur.data = gridData.slice();
        saveArtworks(list);
      }
      renderGallery();
      updatePreview();
      scheduleSave();
    }

    function newArtwork(data, name) {
      const list = loadArtworks();
      const art = {
        id: 'art_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7),
        name: name || ('Sketch ' + (list.length + 1)),
        data: data || randomFace()
      };
      list.push(art);
      saveArtworks(list);
      selectArtwork(art.id);
      return art;
    }

    function cloneArtwork(id) {
      const list = loadArtworks();
      const src = list.find(a => a.id === id);
      if (!src) return;
      newArtwork(src.data.slice(), src.name + ' copy');
    }

    function deleteArtwork(id) {
      let list = loadArtworks().filter(a => a.id !== id);
      saveArtworks(list);
      if (currentArtworkId === id) {
        if (list.length) selectArtwork(list[0].id);
        else newArtwork();
      } else {
        renderGallery();
      }
    }

    /// Loading a piece into the editor is the one deliberate button press —
    /// it replaces what's on the canvas, so it shouldn't happen by accident.
    function selectArtwork(id) {
      const art = loadArtworks().find(a => a.id === id);
      if (!art) return;
      currentArtworkId = id;
      localStorage.setItem('gamenight_current_artwork', id);
      gridData = art.data.slice();
      renderGrid();
      renderGallery();
      updatePreview();
      scheduleSave();
    }

    function renderGallery() {
      const el = document.getElementById('artwork-gallery');
      if (!el) return;
      const list = loadArtworks();
      el.innerHTML = '';

      list.forEach(art => {
        const row = document.createElement('div');
        row.className = 'artwork-row' + (art.id === currentArtworkId ? ' active' : '');

        const cvs = document.createElement('canvas');
        cvs.width = GRID_SIZE; cvs.height = GRID_SIZE;
        const ctx = cvs.getContext('2d');
        art.data.forEach((col, i) => {
          if (col) { ctx.fillStyle = col; ctx.fillRect(i % GRID_SIZE, Math.floor(i / GRID_SIZE), 1, 1); }
        });
        row.appendChild(cvs);

        if (art.id === currentArtworkId) {
          const badge = document.createElement('div');
          badge.className = 'badge';
          badge.innerText = 'Editing';
          row.appendChild(badge);
        }

        // Loading replaces the canvas, so it stays a deliberate press.
        const load = document.createElement('button');
        load.innerText = 'Load';
        load.onclick = () => selectArtwork(art.id);
        const clone = document.createElement('button');
        clone.innerText = 'Copy';
        clone.onclick = () => cloneArtwork(art.id);
        const del = document.createElement('button');
        del.innerText = 'Delete';
        del.onclick = () => deleteArtwork(art.id);
        const actions = document.createElement('div');
        actions.className = 'row-actions';
        actions.append(load, clone, del);
        row.appendChild(actions);
        el.appendChild(row);
      });
    }


  
document.getElementById("studio-action-0").addEventListener("click", function(event) { switchTab('character') });
document.getElementById("studio-action-1").addEventListener("click", function(event) { switchTab('session') });
document.getElementById("studio-action-2").addEventListener("click", function(event) { switchTab('playlist') });
document.getElementById("studio-action-3").addEventListener("click", function(event) { loadPlaylist() });
document.getElementById("outfit-guide-toggle").addEventListener("click", function(event) { toggleOutfitGuide() });
document.getElementById("studio-action-5").addEventListener("click", function(event) { setBrushSize(1) });
document.getElementById("studio-action-6").addEventListener("click", function(event) { setBrushSize(2) });
document.getElementById("studio-action-7").addEventListener("click", function(event) { setBrushSize(4) });
document.getElementById("studio-action-8").addEventListener("click", function(event) { setBrushSize(8) });
document.getElementById("tool-pencil").addEventListener("click", function(event) { setTool('pencil') });
document.getElementById("tool-eraser").addEventListener("click", function(event) { setTool('eraser') });
document.getElementById("tool-fill").addEventListener("click", function(event) { setTool('fill') });
document.getElementById("btn-undo").addEventListener("click", function(event) { undo() });
document.getElementById("studio-action-13").addEventListener("click", function(event) { clearCanvas() });
document.getElementById("studio-action-14").addEventListener("click", function(event) { loadPreset() });
document.getElementById("studio-action-15").addEventListener("click", function(event) { newArtwork() });
document.getElementById("studio-action-16").addEventListener("click", function(event) { exportBackup() });
document.getElementById("studio-action-17").addEventListener("click", function(event) { document.getElementById('backup-file').click() });
document.getElementById("studio-action-18").addEventListener("click", function(event) { exportFacePng() });
document.getElementById("backup-file").addEventListener("change", function(event) { importBackup(this) });
document.getElementById("studio-action-20").addEventListener("click", function(event) { copyBackup() });
document.getElementById("studio-action-21").addEventListener("click", function(event) { importBackup({files:[new File([document.getElementById('restore-text').value], 'backup.json')],value:''}) });

init();
