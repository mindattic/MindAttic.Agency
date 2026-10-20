export default {
  defaultTheme: 'dark',
  start: () => {
    document.querySelectorAll('article pre').forEach(pre => {
      if (pre.querySelector('.ma-copy')) return
      const btn = document.createElement('button')
      btn.type = 'button'
      btn.className = 'ma-copy'
      btn.textContent = 'copy'
      btn.setAttribute('aria-label', 'Copy code')
      btn.addEventListener('click', () => {
        const text = (pre.querySelector('code') || pre).textContent
        if (!navigator.clipboard) return
        navigator.clipboard.writeText(text).then(() => {
          btn.textContent = 'copied!'
          btn.classList.add('ok')
          setTimeout(() => { btn.textContent = 'copy'; btn.classList.remove('ok') }, 1800)
        }).catch(() => {})
      })
      pre.appendChild(btn)
    })
  }
}
