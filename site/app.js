const preview = document.querySelector('#menu-demo');
for (const radio of document.querySelectorAll('input[name="appearance"]')) {
  radio.addEventListener('change', () => {
    preview.className = `menu-demo ${radio.value}`;
    const labels = { circle: '', circlePercent: '64', percent: '64%', time: '42m' };
    preview.querySelector('.menu-value').textContent = labels[radio.value];
  });
}
