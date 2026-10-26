(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  var info = null;
  var selected = null;      // выбранная сеть {ssid, secured}
  var connectedSsid = null; // сеть, к которой устройство подключилось
  var pollTimer = null;

  function api(path, options) {
    return fetch(path, Object.assign({ credentials: 'same-origin' }, options)).then(function (r) {
      if (r.status === 401) {
        location.href = '/login';
        throw new Error('unauthorized');
      }
      return r.json().then(function (body) { return { ok: r.ok, body: body }; });
    });
  }

  function post(path, fields) {
    return api(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(fields).toString()
    });
  }

  function setStatus(el, text, cls) {
    el.textContent = text;
    el.className = cls || '';
  }

  // ---- подсказки «?» ----

  document.querySelectorAll('.help').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var hint = $(btn.dataset.help);
      hint.hidden = !hint.hidden;
    });
  });

  // ---- выбор режима ----

  document.querySelectorAll('input[name=mode]').forEach(function (radio) {
    radio.addEventListener('change', function () { showMode(radio.value); });
  });

  function showMode(mode) {
    $('panel-direct').hidden = mode !== 'direct';
    $('panel-bastion').hidden = mode !== 'bastion';
    $('apply-error').hidden = true;
    if (mode === 'bastion' && !$('networks').children.length) scan();
  }

  // ---- Direct ----

  $('apply-direct').addEventListener('click', function () {
    apply({ mode: 'direct' }, function () {
      return 'Интерфейс настройки закрыт. Подключитесь к Wi-Fi «' + info.direct.ssid +
        '» (пароль ' + info.direct.password + ') и откройте ' + info.direct.url;
    });
  });

  // ---- Bastion: поиск сетей ----

  function signal(rssi) {
    var bars = rssi >= -55 ? 4 : rssi >= -67 ? 3 : rssi >= -75 ? 2 : 1;
    return '▂▄▆█'.slice(0, bars);
  }

  function scan() {
    var list = $('networks');
    list.textContent = '';
    $('scan').disabled = true;
    setStatus($('scan-status'), 'Поиск сетей…', 'muted');

    api('/api/wifi/scan').then(function (res) {
      if (!res.ok) throw new Error();
      var nets = res.body.networks;
      setStatus($('scan-status'), nets.length ? '' : 'Сети не найдены', 'muted');
      nets.forEach(function (n) {
        var li = document.createElement('li');
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'network';
        var name = document.createElement('span');
        name.textContent = n.ssid;
        var meta = document.createElement('span');
        meta.className = 'muted';
        meta.textContent = (n.secured ? '🔒 ' : '') + signal(n.rssi);
        btn.append(name, meta);
        btn.addEventListener('click', function () { selectNetwork(n, btn); });
        li.append(btn);
        list.append(li);
      });
    }).catch(function () {
      setStatus($('scan-status'), 'Не удалось выполнить поиск, попробуйте ещё раз', 'error');
    }).finally(function () {
      $('scan').disabled = false;
    });
  }

  $('scan').addEventListener('click', scan);

  function selectNetwork(n, btn) {
    selected = n;
    document.querySelectorAll('.network').forEach(function (b) { b.classList.remove('selected'); });
    btn.classList.add('selected');
    $('wifi-ssid').textContent = n.ssid;
    $('wifi-password-label').hidden = !n.secured;
    $('wifi-password').value = '';
    $('wifi-form').hidden = false;
    setStatus($('wifi-status'), '');
    if (n.secured) $('wifi-password').focus();
  }

  // ---- Bastion: подключение ----

  var failText = {
    wrong_password: 'Неверный пароль',
    not_found: 'Сеть не найдена',
    other: 'Не удалось подключиться'
  };

  $('wifi-form').addEventListener('submit', function (e) {
    e.preventDefault();
    if (!selected) return;
    connectedSsid = null;
    updateApply();
    setStatus($('wifi-status'), 'Подключение к «' + selected.ssid + '»…', 'muted');

    post('/api/wifi/connect', { ssid: selected.ssid, password: $('wifi-password').value })
      .then(function (res) {
        if (!res.ok) throw new Error(res.body.error);
        pollStatus(Date.now() + 40000);
      })
      .catch(function () {
        setStatus($('wifi-status'), 'Не удалось начать подключение', 'error');
      });
  });

  // Пока устройство переключает канал, связь со страницей может прерываться — ошибки сети пропускаем
  function pollStatus(deadline) {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(function () {
      api('/api/wifi/status').then(function (res) {
        var s = res.body;
        if (s.state === 'connected') {
          connectedSsid = s.ssid;
          setStatus($('wifi-status'), 'Подключено к «' + s.ssid + '», адрес ' + s.ip, 'success');
          updateApply();
        } else if (s.state === 'failed') {
          var text = failText[s.fail] || failText.other;
          setStatus($('wifi-status'), text + (s.fail === 'other' ? ' (код ' + s.reason + ')' : ''), 'error');
        } else if (Date.now() < deadline) {
          pollStatus(deadline);
        } else {
          setStatus($('wifi-status'), 'Подключение не удалось за 40 секунд', 'error');
        }
      }).catch(function () {
        if (Date.now() < deadline) pollStatus(deadline);
      });
    }, 1000);
  }

  function updateApply() {
    $('apply-bastion').disabled = !(connectedSsid && $('bastion').value.trim());
  }

  $('bastion').addEventListener('input', updateApply);

  $('apply-bastion').addEventListener('click', function () {
    var addr = $('bastion').value.trim();
    apply({ mode: 'bastion', ssid: connectedSsid, password: $('wifi-password').value, bastion: addr }, function () {
      return 'Интерфейс настройки закрыт. Устройство подключено к «' + connectedSsid +
        '» и будет подключаться к бастиону ' + addr + '.';
    });
  });

  // ---- применение ----

  var applyErrors = {
    invalid_bastion: 'Проверьте адрес бастиона: IP, домен или bastion.local, можно с портом',
    wifi_not_connected: 'Устройство не подключено к выбранной сети, подключитесь заново'
  };

  function apply(fields, doneText) {
    $('apply-error').hidden = true;
    post('/api/setup/apply', fields).then(function (res) {
      if (!res.ok) {
        $('apply-error').textContent = applyErrors[res.body.error] || 'Не удалось применить настройки';
        $('apply-error').hidden = false;
        return;
      }
      $('wizard').hidden = true;
      $('done-text').textContent = doneText();
      $('done').hidden = false;
    }).catch(function () {
      $('apply-error').textContent = 'Нет связи с устройством';
      $('apply-error').hidden = false;
    });
  }

  // ---- начальная загрузка ----

  api('/api/setup/info').then(function (res) {
    info = res.body;
    ['ssid', 'password', 'url'].forEach(function (k) {
      document.querySelector('[data-direct="' + k + '"]').textContent = info.direct[k];
    });
    $('bastion').value = info.saved.bastion || '';
    var radio = document.querySelector('input[name=mode][value="' + info.saved.mode + '"]');
    if (radio) {
      radio.checked = true;
      showMode(info.saved.mode);
    }
  }).catch(function () {});

  function duration(s) {
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return (d ? d + ' д ' : '') + (d || h ? h + ' ч ' : '') + m + ' мин';
  }

  function kib(bytes) {
    return Math.round(bytes / 1024) + ' КБ';
  }

  api('/api/status').then(function (res) {
    var s = res.body;
    var set = function (k, v) { document.querySelector('[data-key="' + k + '"]').textContent = v; };
    set('firmware', s.firmware);
    set('idf', s.idf);
    set('mac', s.mac);
    set('uptime', duration(s.uptime_s));
    set('heap', kib(s.heap_internal) + ' / ' + kib(s.heap_psram));
  }).catch(function () {});
})();
