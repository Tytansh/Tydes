const header = document.querySelector('[data-header]');
const menuButton = document.querySelector('[data-menu-button]');
const menu = document.querySelector('[data-menu]');

const updateHeader = () => {
  header?.classList.toggle('is-scrolled', window.scrollY > 12);
};

updateHeader();
window.addEventListener('scroll', updateHeader, { passive: true });

menuButton?.addEventListener('click', () => {
  const isOpen = menuButton.getAttribute('aria-expanded') === 'true';
  menuButton.setAttribute('aria-expanded', String(!isOpen));
  menu?.classList.toggle('is-open', !isOpen);
  document.body.classList.toggle('menu-open', !isOpen);
});

menu?.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', () => {
    menuButton?.setAttribute('aria-expanded', 'false');
    menu.classList.remove('is-open');
    document.body.classList.remove('menu-open');
  });
});

const revealItems = document.querySelectorAll('.reveal');
if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12 },
  );
  revealItems.forEach((item) => observer.observe(item));
} else {
  revealItems.forEach((item) => item.classList.add('is-visible'));
}

const productScreens = {
  spots: {
    kicker: 'SPOT DISCOVERY',
    title: 'Search less. Surf more.',
    copy: 'Compare breaks, skill level, live conditions and local context before committing to the drive or paddle.',
    points: ['Forecast cards and tide context', 'Favorites and map discovery', 'Regional surf guides'],
    image: '/assets/spots.png',
    alt: 'Tydes Spots screen showing surf destinations and nearby breaks',
  },
  travel: {
    kicker: 'TRIP PLANNING',
    title: 'Build the trip around the break.',
    copy: 'Choose a surf base, understand the waves nearby and compare stay types without losing the thread of the trip.',
    points: ['Surf-zone-first destination search', 'Nearby breaks and local context', 'Official accommodation handoff'],
    image: '/assets/travel.png',
    alt: 'Tydes Travel screen showing Uluwatu and Siargao surf bases',
  },
  feed: {
    kicker: 'SURF COMMUNITY',
    title: 'Know who is around.',
    copy: 'Follow local updates, join surf events and keep trip conversations close to the places they are about.',
    points: ['Profiles, posts and comments', 'Surf events and crews', 'Direct trip conversations'],
    image: '/assets/feed.png',
    alt: 'Tydes Feed screen showing a local surf community post',
  },
  alerts: {
    kicker: 'CONDITION ALERTS',
    title: 'Watch the window, not the screen.',
    copy: 'Set wave, wind and tide preferences for the breaks that matter and let Tydes keep an eye on the setup.',
    points: ['Wave-height thresholds', 'Wind and tide preferences', 'Break-specific monitoring'],
    image: '/assets/alerts.png',
    alt: 'Tydes Alerts screen showing surf condition monitoring',
  },
};

const demo = document.querySelector('[data-product-demo]');
if (demo) {
  const tabs = [...demo.querySelectorAll('[data-screen]')];
  const image = demo.querySelector('[data-stage-image]');
  const phone = image?.closest('.phone-demo');
  const kicker = demo.querySelector('[data-stage-kicker]');
  const title = demo.querySelector('[data-stage-title]');
  const copy = demo.querySelector('[data-stage-copy]');
  const points = demo.querySelector('[data-stage-points]');

  const selectScreen = (key) => {
    const screen = productScreens[key];
    if (!screen) return;
    tabs.forEach((tab) => {
      const active = tab.dataset.screen === key;
      tab.classList.toggle('is-active', active);
      tab.setAttribute('aria-selected', String(active));
    });
    phone?.classList.add('is-changing');
    window.setTimeout(() => {
      kicker.textContent = screen.kicker;
      title.textContent = screen.title;
      copy.textContent = screen.copy;
      points.innerHTML = screen.points.map((point) => `<li>${point}</li>`).join('');
      image.src = screen.image;
      image.alt = screen.alt;
      phone?.classList.remove('is-changing');
    }, 150);
  };

  tabs.forEach((tab) => tab.addEventListener('click', () => selectScreen(tab.dataset.screen)));
}
