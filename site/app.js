const dialog = document.querySelector('#image-dialog');
const enlarged = document.querySelector('#enlarged-image');
const caption = document.querySelector('#image-caption');
let lastTrigger;
for (const button of document.querySelectorAll('[data-image]')) {
  button.addEventListener('click', () => {
    lastTrigger = button;
    enlarged.src = button.dataset.image;
    enlarged.alt = button.querySelector('img').alt;
    caption.textContent = button.dataset.caption;
    dialog.showModal();
  });
}
document.querySelector('.close-dialog').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', (event) => {
  const box = dialog.getBoundingClientRect();
  if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) dialog.close();
});
dialog.addEventListener('close', () => lastTrigger?.focus({ preventScroll: true }));
