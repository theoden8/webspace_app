  // Image and looped-video sources drawn onto a capture canvas, for the
  // visual kinds. Leaves the kind's code `loadSource(source, missing)` and
  // `canvasStream(canvas, draw, fps, meta)`.
  function loadImage(dataUrl) {
    return new Promise(function(resolve, reject) {
      var img = new Image();
      img.onload = function() { resolve(img); };
      img.onerror = function() { reject(notAllowed('Could not decode the selected image')); };
      img.src = dataUrl;
    });
  }

  function loadVideo(dataUrl) {
    return new Promise(function(resolve, reject) {
      var vid = document.createElement('video');
      vid.muted = true;
      vid.defaultMuted = true;
      vid.loop = true;
      vid.playsInline = true;
      vid.setAttribute('playsinline', '');
      vid.oncanplay = function() {
        var p = vid.play();
        if (p && p.catch) p.catch(function() {});
        resolve(vid);
      };
      vid.onerror = function() { reject(notAllowed('Could not decode the selected video')); };
      vid.src = dataUrl;
      try { vid.load(); } catch (e) {}
    });
  }

  // The picked file, decoded: an <img>, or a muted looping <video>.
  function loadSource(source, missing) {
    if (!source || !source.dataUrl) return Promise.reject(notAllowed(missing));
    var isVideo = source.kind === 'video';
    return (isVideo ? loadVideo(source.dataUrl) : loadImage(source.dataUrl))
      .then(function(media) { return { media: media, isVideo: isVideo }; });
  }

  // The canvas's captured stream, repainted by `draw` at `fps`. The canvas is
  // kept out of the document: captureStream() does not require the element to
  // be rendered, and inserting it would let the page see it in the DOM.
  //
  // Keeps painting so a consumer sampling frames over time keeps seeing the
  // source. A still image needs the repaint too: captureStream(fps) only
  // emits a frame when the canvas is touched, and a stream that stops after
  // its first frame stalls consumers that wait for several.
  function canvasStream(canvas, draw, fps, meta) {
    draw();
    var stream = canvas.captureStream(fps);
    var timer = setInterval(draw, Math.max(1000 / fps, 16));
    var track = stream.getVideoTracks()[0];
    meta.release = function() {
      clearInterval(timer);
      if (meta.isVideo) { try { meta.media.pause(); } catch (e) {} }
    };
    if (track) {
      presentSynthetic(track, meta);
      // A canvas track is a CanvasCaptureMediaStreamTrack; a device or
      // display track is a plain MediaStreamTrack, and the constructor name is
      // readable via the prototype chain. Internal slots live on the
      // instance, so the track keeps working; if any engine disagrees, the
      // try/catch leaves the honest prototype in place.
      try {
        if (globalThis.MediaStreamTrack &&
            Object.getPrototypeOf(track) !== globalThis.MediaStreamTrack.prototype) {
          Object.setPrototypeOf(track, globalThis.MediaStreamTrack.prototype);
        }
      } catch (e) {}
    }
    return stream;
  }
