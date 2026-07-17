import { Link } from 'react-router-dom'

const FEATURES = [
  {
    icon: '🤖',
    title: 'AI-Powered Dispatch',
    text: 'Drop a rate confirmation PDF and watch the load build itself — customer, stops, times, and rate extracted in seconds.',
  },
  {
    icon: '📦',
    title: 'Full Load Lifecycle',
    text: 'Six clear stages from pending to billed, enforced automatically. No skipped steps, no lost paperwork, complete audit trail.',
  },
  {
    icon: '📍',
    title: 'Automatic Mileage',
    text: 'Real road miles calculated the moment you enter pickup and delivery. Rate-per-mile computed on every load.',
  },
  {
    icon: '🧾',
    title: 'One-Click Invoicing',
    text: 'Turn completed loads into professional PDF invoices in seconds. Track draft, sent, and paid — nothing falls through.',
  },
  {
    icon: '💵',
    title: 'Weekly Driver Settlements',
    text: 'Monday-to-Sunday reports per truck and driver with pay computed from stored per-mile rates. Settlement day becomes minutes.',
  },
  {
    icon: '🚛',
    title: 'Fleet & Maintenance',
    text: 'Trucks, trailers, repairs, and costs in one place. License and equipment alerts before they become problems.',
  },
]

const STEPS = [
  { n: '1', title: 'Drop the rate con', text: 'AI reads the PDF and pre-fills the entire load.' },
  { n: '2', title: 'Assign & roll', text: 'Driver, truck, trailer — equipment status syncs itself.' },
  { n: '3', title: 'Deliver & bill', text: 'Advance the load, generate the invoice, run weekly pay.' },
]

export default function Landing() {
  return (
    <div className="min-h-screen bg-surface text-body">
      {/* Nav */}
      <header className="sticky top-0 z-20 border-b border-white/10 bg-navy-900/95 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-4 sm:px-6">
          <div className="flex items-center gap-2 text-white">
            <img src="/brand/truxon-primary-white.png" alt="Truxon" className="h-7 w-auto" />
            <span className="ml-1 hidden rounded-full bg-white/10 px-2 py-0.5 text-xs font-medium text-navy-100 sm:inline">TMS</span>
          </div>
          <nav className="hidden items-center gap-8 text-sm font-medium text-navy-100 md:flex">
            <a href="#features" className="hover:text-white">Features</a>
            <a href="#how" className="hover:text-white">How it works</a>
            <a href="#contact" className="hover:text-white">Contact</a>
          </nav>
          <Link
            to="/login"
            className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-semibold text-white shadow-lg shadow-blue-600/30 transition-colors hover:bg-blue-500"
          >
            Log In / Sign Up
          </Link>
        </div>
      </header>

      {/* Hero */}
      <section className="bg-navy-900 text-white">
        <div className="mx-auto max-w-6xl px-4 py-20 text-center sm:px-6 lg:py-28">
          <p className="mb-4 inline-block rounded-full border border-blue-400/40 bg-blue-500/10 px-4 py-1 text-sm font-medium text-blue-300">
            Transportation Management System
          </p>
          <h1 className="mx-auto max-w-3xl text-4xl font-extrabold leading-tight sm:text-5xl lg:text-6xl">
            Run your trucking company from <span className="text-blue-400">one screen</span>
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-lg text-navy-100">
            Dispatch, loads, drivers, invoicing, and weekly settlements — built for small and mid-sized carriers
            who are done juggling spreadsheets, and fast enough to use from the cab on a tablet.
          </p>
          <div className="mt-10 flex flex-wrap items-center justify-center gap-4">
            <a
              href="#contact"
              className="rounded-lg bg-blue-600 px-8 py-3.5 text-base font-semibold text-white shadow-lg shadow-blue-600/30 transition-colors hover:bg-blue-500"
            >
              Request a Demo
            </a>
            <a
              href="#features"
              className="rounded-lg border border-white/25 px-8 py-3.5 text-base font-semibold text-white transition-colors hover:bg-white/10"
            >
              See what's inside
            </a>
          </div>
          {/* Stats strip */}
          <div className="mx-auto mt-16 grid max-w-3xl grid-cols-1 gap-6 sm:grid-cols-3">
            {[
              ['< 30 sec', 'from rate con PDF to dispatched load'],
              ['6 stages', 'of load tracking, enforced automatically'],
              ['1 click', 'from completed loads to a PDF invoice'],
            ].map(([big, small]) => (
              <div key={big} className="rounded-2xl border border-white/10 bg-white/5 p-6">
                <div className="text-3xl font-extrabold text-blue-400">{big}</div>
                <div className="mt-1 text-sm text-navy-100">{small}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Features */}
      <section id="features" className="mx-auto max-w-6xl px-4 py-20 sm:px-6">
        <h2 className="text-center text-3xl font-bold text-body sm:text-4xl">Everything a carrier needs. Nothing it doesn't.</h2>
        <p className="mx-auto mt-3 max-w-2xl text-center text-muted">
          Every module talks to the others — assign a truck and its status updates, complete a load and it's ready to bill.
        </p>
        <div className="mt-12 grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map((f) => (
            <div key={f.title} className="rounded-2xl border border-line bg-surface p-7 shadow-sm transition-shadow hover:shadow-md">
              <div className="text-3xl">{f.icon}</div>
              <h3 className="mt-4 text-lg font-semibold text-body">{f.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-muted">{f.text}</p>
            </div>
          ))}
        </div>
      </section>

      {/* How it works */}
      <section id="how" className="bg-surface-2 py-20">
        <div className="mx-auto max-w-6xl px-4 sm:px-6">
          <h2 className="text-center text-3xl font-bold text-body sm:text-4xl">From email attachment to paid invoice</h2>
          <div className="mt-12 grid grid-cols-1 gap-8 md:grid-cols-3">
            {STEPS.map((s) => (
              <div key={s.n} className="relative rounded-2xl bg-surface p-8 shadow-sm">
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-blue-600 text-lg font-bold text-white">{s.n}</div>
                <h3 className="mt-4 text-lg font-semibold text-body">{s.title}</h3>
                <p className="mt-2 text-sm text-muted">{s.text}</p>
              </div>
            ))}
          </div>
          <div className="mt-12 rounded-2xl bg-navy-900 p-8 text-center text-white sm:p-12">
            <h3 className="text-2xl font-bold sm:text-3xl">Secure by design</h3>
            <p className="mx-auto mt-3 max-w-2xl text-navy-100">
              Role-based access for dispatchers, accountants, and mechanics. Every change audit-logged.
              Business rules enforced in the database itself — encrypted in transit and at rest, with automated backups.
            </p>
          </div>
        </div>
      </section>

      {/* CTA / Contact */}
      <section id="contact" className="mx-auto max-w-6xl px-4 py-20 text-center sm:px-6">
        <h2 className="text-3xl font-bold text-body sm:text-4xl">Ready to see it on your loads?</h2>
        <p className="mx-auto mt-3 max-w-xl text-muted">
          Get a walkthrough with your own rate confirmations and see the difference on day one.
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-4">
          <a
            href="mailto:sales@truxon.com?subject=Truxon%20TMS%20Demo%20Request"
            className="rounded-lg bg-blue-600 px-8 py-3.5 text-base font-semibold text-white shadow-lg shadow-blue-600/30 transition-colors hover:bg-blue-500"
          >
            Request a Demo
          </a>
          <Link to="/login" className="rounded-lg border border-line px-8 py-3.5 text-base font-semibold text-brand transition-colors hover:bg-surface-2">
            Existing customer? Log in
          </Link>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-line bg-surface-2">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-4 py-8 text-sm text-muted sm:flex-row sm:px-6">
          <div className="flex items-center gap-2">
            <img src="/brand/truxon-icon-color.svg" alt="Truxon" className="h-6 w-6" />
            <span className="font-semibold text-body">Truxon</span>
            <span>© {new Date().getFullYear()}</span>
          </div>
          <div className="flex gap-6">
            <a href="#features" className="hover:text-brand">Features</a>
            <a href="#contact" className="hover:text-brand">Contact</a>
            <Link to="/login" className="hover:text-brand">Log in</Link>
          </div>
        </div>
      </footer>
    </div>
  )
}
