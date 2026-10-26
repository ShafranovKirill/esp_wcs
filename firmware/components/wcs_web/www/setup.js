(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  var info = null;
  var mode = null;          // выбранный режим: 'direct' | 'bastion'
  var selected = null;      // выбранная сеть {ssid, secured}
  var pending = null;       // подключение в процессе {ssid, password}
  var connected = null;     // сеть, к которой устройство подключилось {ssid, password, ip}
  var check = null;         // результат проверки бастиона {addr, ok, text}
  var applied = false;
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

  // ---- шаги мастера ----

  // Шаг, на который ведёт «Назад», и номер шага в своей ветке
  var steps = {
    mode:    { back: null,      n: 1 },
    direct:  { back: 'mode',    n: 2, of: 2 },
    wifi:    { back: 'mode',    n: 2, of: 4 },
    bastion: { back: 'wifi',    n: 3, of: 4 },
    confirm: { back: 'bastion', n: 4, of: 4 },
    done:    { back: null }
  };

  // Куда можно попасть сейчас: без выполненных условий — откат на шаг раньше
  function allowed(step) {
    if (applied) return 'done';
    switch (step) {
      case 'direct': return 'direct';
      case 'wifi': return 'wifi';
      case 'bastion': return connected ? 'bastion' : 'wifi';
      case 'confirm':
        if (!connected) return 'wifi';
        return check && check.addr === bastionAddr() ? 'confirm' : 'bastion';
      default: return 'mode';
    }
  }

  function go(step) {
    location.hash = step;
  }

  function render() {
    var want = location.hash.slice(1);
    var step = allowed(want);
    if (step !== want) {
      history.replaceState(null, '', '#' + step);
    }
    document.querySelectorAll('.step').forEach(function (s) {
      s.hidden = s.dataset.step !== step;
    });
    $('apply-error').hidden = true;

    var st = steps[step];
    $('progress').textContent = !st.n ? '' : st.of ? 'Шаг ' + st.n + ' из ' + st.of : 'Шаг 1';

    if (step === 'wifi' && !$('networks').children.length) scan();
    if (step === 'bastion') updateBastion();
    if (step === 'confirm') fillConfirm();
  }

  window.addEventListener('hashchange', render);

  document.querySelectorAll('[data-back]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      go(steps[location.hash.slice(1)].back);
    });
  });

  // ---- подсказки «?» ----

  document.querySelectorAll('.help').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var hint = $(btn.dataset.help);
      hint.hidden = !hint.hidden;
    });
  });

  // ---- шаг 1: режим ----

  document.querySelectorAll('input[name=mode]').forEach(function (radio) {
    radio.addEventListener('change', function () {
      mode = radio.value;
      $('mode-next').disabled = false;
    });
  });

  $('mode-next').addEventListener('click', function () {
    go(mode === 'direct' ? 'direct' : 'wifi');
  });

  // ---- Direct ----

  $('apply-direct').addEventListener('click', function () {
    apply({ mode: 'direct' }, function () {
      return 'Интерфейс настройки закрыт. Подключитесь к Wi-Fi «' + info.direct.ssid +
        '» (пароль ' + info.direct.password + ') и откройте ' + info.direct.url;
    });
  });

  // ---- Bastion, шаг 2: Wi-Fi ----

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
        if (connected && connected.ssid === n.ssid) btn.classList.add('selected');
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
    if (n.secured) $('wifi-password').focus();
  }

  var failText = {
    wrong_password: 'Неверный пароль',
    not_found: 'Сеть не найдена',
    other: 'Не удалось подключиться'
  };

  function setConnected(c) {
    connected = c;
    check = null;
    $('wifi-next').disabled = !connected;
  }

  $('wifi-form').addEventListener('submit', function (e) {
    e.preventDefault();
    if (!selected) return;
    pending = { ssid: selected.ssid, password: selected.secured ? $('wifi-password').value : '' };
    setConnected(null);
    $('wifi-connect').disabled = true;
    setStatus($('wifi-status'), 'Подключение к «' + pending.ssid + '»…', 'muted');

    post('/api/wifi/connect', pending)
      .then(function (res) {
        if (!res.ok) throw new Error(res.body.error);
        pollStatus(Date.now() + 40000);
      })
      .catch(function () {
        $('wifi-connect').disabled = false;
        setStatus($('wifi-status'), 'Не удалось начать подключение', 'error');
      });
  });

  // Пока устройство переключает канал, связь со страницей может прерываться — ошибки сети пропускаем
  function pollStatus(deadline) {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(function () {
      api('/api/wifi/status').then(function (res) {
        var s = res.body;
        if (s.state === 'connected' && s.ssid === pending.ssid) {
          setConnected({ ssid: s.ssid, password: pending.password, ip: s.ip });
          $('wifi-connect').disabled = false;
          setStatus($('wifi-status'), 'Подключено к «' + s.ssid + '», адрес ' + s.ip, 'success');
        } else if (s.state === 'failed') {
          $('wifi-connect').disabled = false;
          var text = failText[s.fail] || failText.other;
          setStatus($('wifi-status'), text + (s.fail === 'other' ? ' (код ' + s.reason + ')' : ''), 'error');
        } else if (Date.now() < deadline) {
          pollStatus(deadline);
        } else {
          $('wifi-connect').disabled = false;
          setStatus($('wifi-status'), 'Подключение не удалось за 40 секунд', 'error');
        }
      }).catch(function () {
        if (Date.now() < deadline) {
          pollStatus(deadline);
        } else {
          $('wifi-connect').disabled = false;
          setStatus($('wifi-status'), 'Нет связи с устройством', 'error');
        }
      });
    }, 1000);
  }

  $('wifi-next').addEventListener('click', function () { go('bastion'); });

  // ---- Bastion, шаг 3: адрес и проверка ----

  function bastionAddr() {
    return $('bastion').value.trim();
  }

  function updateBastion() {
    var fresh = check && check.addr === bastionAddr();
    $('bastion-check').disabled = !bastionAddr();
    $('bastion-next').disabled = !fresh;
    $('bastion-next').textContent = fresh && !check.ok ? 'Продолжить без проверки' : 'Далее';
  }

  // Адрес поменялся — прошлая проверка к нему не относится
  $('bastion').addEventListener('input', function () {
    check = null;
    setStatus($('bastion-status'), '');
    updateBastion();
  });

  function hostPort(r) {
    return r.ip + ':' + r.port;
  }

  var checkText = {
    ok: function (r) { return 'Бастион доступен: ' + hostPort(r) + ', ' + r.time_ms + ' мс'; },
    not_resolved: function () { return 'Имя не найдено: проверьте адрес или укажите IP'; },
    refused: function (r) { return 'Хост ' + r.ip + ' отвечает, но порт ' + r.port + ' закрыт: бастион не запущен или слушает другой порт'; },
    timeout: function (r) { return 'Нет ответа от ' + hostPort(r) + ': хост выключен или порт закрыт файрволом'; },
    unreachable: function (r) { return 'Нет маршрута до ' + r.ip + ' из сети «' + connected.ssid + '»'; }
  };

  var checkErrors = {
    invalid_bastion: 'Проверьте адрес: IP, домен или имя .local, порт — через двоеточие',
    wifi_not_connected: 'Устройство отключилось от Wi-Fi, вернитесь на шаг назад и подключитесь заново'
  };

  $('bastion-form').addEventListener('submit', function (e) {
    e.preventDefault();
    var addr = bastionAddr();
    if (!addr) return;
    check = null;
    updateBastion();
    $('bastion-check').disabled = true;
    setStatus($('bastion-status'), 'Проверка ' + addr + '…', 'muted');

    post('/api/bastion/check', { bastion: addr }).then(function (res) {
      if (bastionAddr() !== addr) return; // адрес успели поменять
      if (!res.ok) {
        setStatus($('bastion-status'), checkErrors[res.body.error] || 'Не удалось проверить', 'error');
        return;
      }
      var r = res.body;
      check = { addr: addr, ok: r.result === 'ok', text: (checkText[r.result] || checkText.unreachable)(r) };
      setStatus($('bastion-status'), check.text, check.ok ? 'success' : 'error');
    }).catch(function () {
      setStatus($('bastion-status'), 'Нет связи с устройством, попробуйте ещё раз', 'error');
    }).finally(updateBastion);
  });

  $('bastion-next').addEventListener('click', function () { go('confirm'); });

  // ---- Bastion, шаг 4: подтверждение ----

  function fillConfirm() {
    $('confirm-ssid').textContent = connected.ssid;
    $('confirm-ip').textContent = connected.ip;
    $('confirm-bastion').textContent = check.addr;
    $('confirm-check').textContent = check.ok ? 'бастион доступен' : 'не пройдена — ' + check.text;
  }

  $('apply-bastion').addEventListener('click', function () {
    var addr = check.addr;
    apply({ mode: 'bastion', ssid: connected.ssid, password: connected.password, bastion: addr }, function () {
      return 'Интерфейс настройки закрыт. Устройство подключено к «' + connected.ssid +
        '» и будет подключаться к бастиону ' + addr + '.';
    });
  });

  // ---- применение ----

  var applyErrors = {
    invalid_bastion: 'Проверьте адрес бастиона: IP, домен или имя .local, можно с портом',
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
      applied = true;
      $('done-text').textContent = doneText();
      go('done');
    }).catch(function () {
      $('apply-error').textContent = 'Нет связи с устройством';
      $('apply-error').hidden = false;
    });
  }

  // ---- начальная загрузка ----

  render();

  api('/api/setup/info').then(function (res) {
    info = res.body;
    ['ssid', 'password', 'url'].forEach(function (k) {
      document.querySelector('[data-direct="' + k + '"]').textContent = info.direct[k];
    });
    var port = info.bastion_default_port;
    $('bastion-hint').textContent = 'Порт по умолчанию — ' + port + '. Другой укажите через двоеточие: bastion.local:8443';
    $('bastion').value = info.saved.bastion || '';
    updateBastion();
    var radio = document.querySelector('input[name=mode][value="' + info.saved.mode + '"]');
    if (radio) {
      radio.checked = true;
      mode = info.saved.mode;
      $('mode-next').disabled = false;
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
