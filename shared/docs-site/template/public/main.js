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

    // "Back to top" appears once the page has scrolled past the end of the In this article outline
    // (or one screen down where the outline is hidden).
    const top = document.createElement('button')
    top.type = 'button'
    top.className = 'ma-top'
    top.textContent = 'Back to Top'
    top.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' }))
    document.body.appendChild(top)
    const update = () => {
      const affix = document.querySelector('body > main > .affix')
      const end = affix && affix.offsetParent ? affix.getBoundingClientRect().bottom + window.scrollY : window.innerHeight
      top.classList.toggle('show', window.scrollY > end)
    }
    window.addEventListener('scroll', update, { passive: true })
    window.addEventListener('resize', update)
    update()
  }
}
