export default class {
    /**
     * @property {boolean} dark Interal state for dark theme activation.
     * @private
     */
    static #dark = false;

    /**
     * Inialize the theme class.
     */
    static init() {
      // Respect an explicit user choice; otherwise use the stylesheet selected by the template.
      const storedTheme = localStorage.getItem('darkTheme');
      if (storedTheme === null) {
        const stylesheet = document.getElementById('pagestyle').getAttribute('href') || '';
        this.set(/\/dark\.css(?:\?|$)/.test(stylesheet));
      } else {
        this.set(storedTheme === 'true');
      }
    }

    /**
     * Set page theme and update local storage variable.
     *
     * @param {boolean} dark Whether to activate dark theme.
     */
    static set(dark = false) {
      // Preserve any cache-busting query parameter from the current href.
      const current = document.getElementById('pagestyle').getAttribute('href');
      const qIndex = current ? current.indexOf('?') : -1;
      const query = qIndex >= 0 ? current.substring(qIndex) : '';
      // Swap CSS to selected theme
      document.getElementById('pagestyle')
          .setAttribute('href', 'static/css/' + (dark ? 'dark' : 'main') + '.css' + query);

      // Keep the browser chrome and status bar in step with the theme.
      const themeColor = document.querySelector('meta[name="theme-color"]');
      if (themeColor) themeColor.setAttribute('content', dark ? '#000000' : '#f2f2f7');

      // Update local storage
      localStorage.setItem('darkTheme', dark);

      // Update internal state
      this.#dark = dark;
    }

    /**
     * Swap page theme.
     */
    static swap() {
      this.set(!this.#dark);
    }
}
