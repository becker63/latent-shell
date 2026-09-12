"""Minimal document for the generated Python-authored browser host."""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Latent Shell</title>
<link rel="stylesheet" href="/static/xterm.css">
<style>
:root { color-scheme: light; font: 16px/1.7 ui-monospace, monospace; background: #fef7f0; color: #292524; }
* { box-sizing: border-box; }
html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; }
#terminal { width: 100%; height: 100dvh; padding: 12px; }
.xterm { height: 100%; }
dialog { width: min(90vw, 800px); border: 0; padding: 24px; background: #fef7f0; color: inherit; }
dialog::backdrop { background: #fef7f0; }
label { display: block; margin-bottom: 24px; }
.input-line { display: flex; gap: 12px; align-items: baseline; }
input { width: 100%; min-width: 0; border: 0; outline: none; font: inherit; color: inherit; background: transparent; caret-color: #b45309; }
.xterm-viewport { scrollbar-width: thin; scrollbar-color: #d6c6b8 #fef7f0; }
@media (max-width: 600px) { #terminal { padding: 8px; } dialog { padding: 16px; } }
</style>
</head>
<body>
<div id="terminal"></div>
<dialog id="world">
<form method="dialog">
<label for="seed">Describe the computer you want to explore.</label>
<div class="input-line"><span aria-hidden="true">&gt;</span>
<input id="seed" name="seed" type="text" required maxlength="2000" autofocus autocomplete="off" autocapitalize="off" spellcheck="false">
</div>
</form>
</dialog>
<script src="/static/xterm.js"></script>
<script src="/static/xterm-fit.js"></script>
<script src="/static/host.js"></script>
</body>
</html>
"""
