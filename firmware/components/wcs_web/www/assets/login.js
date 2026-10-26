(function () {
  var params = new URLSearchParams(location.search);
  var error = params.get('error');
  if (!error) return;

  var retry = parseInt(params.get('retry') || '0', 10);
  var box = document.getElementById('error');
  var button = document.querySelector('button[type=submit]');

  if (error === 'bad' && retry === 0) {
    box.textContent = 'Неверный логин или пароль';
    box.hidden = false;
    return;
  }

  var prefix = error === 'bad' ? 'Неверный логин или пароль. ' : 'Слишком много попыток. ';
  var deadline = Date.now() + retry * 1000;
  button.disabled = true;
  box.hidden = false;

  (function tick() {
    var left = Math.ceil((deadline - Date.now()) / 1000);
    if (left <= 0) {
      box.textContent = prefix + 'Можно попробовать снова';
      button.disabled = false;
      return;
    }
    box.textContent = prefix + 'Повторите через ' + left + ' с';
    setTimeout(tick, 500);
  })();
})();
