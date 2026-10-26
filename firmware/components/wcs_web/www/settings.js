(function () {
  function set(key, value) {
    var el = document.querySelector('[data-key="' + key + '"]');
    if (el) el.textContent = value;
  }

  function duration(s) {
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return (d ? d + ' д ' : '') + (d || h ? h + ' ч ' : '') + m + ' мин';
  }

  function kib(bytes) {
    return Math.round(bytes / 1024) + ' КБ';
  }

  fetch('/api/status', { credentials: 'same-origin' })
    .then(function (r) {
      if (r.status === 401) { location.href = '/login'; throw new Error('unauthorized'); }
      return r.json();
    })
    .then(function (s) {
      set('firmware', s.firmware);
      set('idf', s.idf);
      set('mac', s.mac);
      set('uptime', duration(s.uptime_s));
      set('heap', kib(s.heap_internal) + ' / ' + kib(s.heap_psram));
    })
    .catch(function () {});
})();
