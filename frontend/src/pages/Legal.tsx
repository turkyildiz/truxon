/** Public legal pages — /privacy and /terms. Written for what Truxon actually
 * does (TMS records, driver GPS during work, AI document processing, optional
 * QuickBooks sync). These URLs are also registered with Intuit as the app's
 * privacy policy / EULA for the QuickBooks integration. */
import { Link } from 'react-router-dom'

function LegalShell({ title, updated, children }: { title: string; updated: string; children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-canvas text-body">
      <header className="border-b border-line bg-surface">
        <div className="mx-auto flex max-w-3xl items-center gap-3 px-4 py-4 sm:px-6">
          <Link to="/" className="flex items-center gap-2">
            <img src="/brand/truxon-icon-color.svg" alt="Truxon" className="h-7 w-7" />
            <span className="text-lg font-bold">Truxon</span>
          </Link>
          <span className="ml-auto text-sm text-muted">
            <Link to="/privacy" className="mr-4 hover:text-brand">Privacy</Link>
            <Link to="/terms" className="hover:text-brand">Terms</Link>
          </span>
        </div>
      </header>
      <main className="mx-auto max-w-3xl px-4 py-10 sm:px-6">
        <h1 className="text-3xl font-bold">{title}</h1>
        <p className="mt-1 text-sm text-muted">Last updated: {updated}</p>
        <div className="prose-legal mt-8 space-y-6 text-[15px] leading-relaxed [&_h2]:mt-8 [&_h2]:text-xl [&_h2]:font-semibold [&_li]:ml-5 [&_li]:list-disc [&_p]:text-body">
          {children}
        </div>
      </main>
      <footer className="border-t border-line py-8 text-center text-sm text-muted">
        Truxon © {new Date().getFullYear()} · <a className="hover:text-brand" href="mailto:sales@truxon.com">sales@truxon.com</a>
      </footer>
    </div>
  )
}

export function Privacy() {
  return (
    <LegalShell title="Privacy Policy" updated="July 19, 2026">
      <p>
        Truxon is a transportation management system (TMS) for trucking carriers. This policy explains what
        information Truxon collects, how it is used, and the choices you have. It applies to the Truxon web
        application, the Truxon driver mobile app, and related services.
      </p>

      <h2>Information we collect</h2>
      <ul>
        <li><strong>Account information</strong> — name, email address, username, and role, provided when an account is created for you.</li>
        <li><strong>Operational records</strong> — the business data a carrier enters or imports to run its operation: loads, customers, dispatch details, invoices, driver and equipment records, fuel and toll transactions, maintenance records, and uploaded documents (for example rate confirmations, bills of lading, and receipts).</li>
        <li><strong>Driver location (GPS)</strong> — the driver mobile app reports vehicle position while a driver is on duty and assigned to a load, so dispatch can track active freight. Location is collected for work purposes, is visible to the carrier's staff, and is not collected from personal devices outside of app use.</li>
        <li><strong>Email intake</strong> — emails sent to a carrier's Truxon intake address (for example forwarded work orders or documents) are processed to create the corresponding records.</li>
      </ul>

      <h2>How we use information</h2>
      <ul>
        <li>To operate the TMS: dispatching, tracking, invoicing, settlements, maintenance, and reporting.</li>
        <li><strong>AI processing</strong> — uploaded documents and intake emails may be processed by large-language-model services (Anthropic Claude) to extract fields (for example load numbers, amounts, dates) and to power the Forest assistant. These providers process data to provide the service and do not use it to train their models.</li>
        <li>To generate mapping and mileage via Google Maps services.</li>
        <li>To send operational notifications (for example load assignments and alerts).</li>
      </ul>

      <h2>QuickBooks integration</h2>
      <p>
        A carrier may optionally connect its own QuickBooks Online company to Truxon. When connected, Truxon
        exchanges accounting data with Intuit on the carrier's behalf — invoices, customers, and payment
        status — solely to keep the two systems in sync. Truxon stores the OAuth tokens securely, never sees
        your Intuit password, and does not share QuickBooks data with any other third party. The connection can
        be revoked at any time from Truxon or from Intuit's connected-apps settings, which immediately stops the
        exchange.
      </p>

      <h2>What we do not do</h2>
      <ul>
        <li>We do not sell personal information.</li>
        <li>We do not use customer data for advertising.</li>
        <li>We do not share data with third parties except the service providers listed here, as required to operate the service, or as required by law.</li>
      </ul>

      <h2>Service providers</h2>
      <p>
        Truxon runs on Supabase (database, authentication, and file storage) and Vercel (web hosting), and uses
        Anthropic (AI document processing and assistant), Google Maps (mileage and mapping), ElevenLabs (optional
        voice output), and Intuit (optional QuickBooks sync). Each processes data only to provide its service.
      </p>

      <h2>Security and retention</h2>
      <p>
        Data is encrypted in transit and at rest, access is enforced per-role at the database level, and encrypted
        backups are kept, including immutable off-site copies, so records survive hardware failure or ransomware.
        Operational records are retained for as long as the carrier's account is active and as required for
        transportation record-keeping obligations (for example IFTA and DOT retention periods), then deleted on
        request.
      </p>

      <h2>Your choices</h2>
      <ul>
        <li>Carriers can export their data or request deletion at any time by contacting us.</li>
        <li>Drivers with questions about workplace location tracking should contact their carrier; the carrier controls what is collected through its Truxon account.</li>
        <li>You may disconnect the QuickBooks integration at any time as described above.</li>
      </ul>

      <h2>Changes and contact</h2>
      <p>
        If this policy changes materially we will note it here with a new date. Questions:&nbsp;
        <a className="text-brand hover:underline" href="mailto:sales@truxon.com">sales@truxon.com</a>.
      </p>
    </LegalShell>
  )
}

export function Terms() {
  return (
    <LegalShell title="Terms of Service" updated="July 19, 2026">
      <p>
        These terms govern use of Truxon, a transportation management system provided for trucking carriers and
        their authorized staff and drivers. By using Truxon you agree to these terms. If you use Truxon on behalf
        of a company, you agree on that company's behalf.
      </p>

      <h2>The service</h2>
      <p>
        Truxon provides dispatching, load tracking, invoicing, driver settlement, fleet maintenance, document
        management, reporting, and related tools, including an AI assistant. Features may evolve; we may add,
        change, or remove functionality to improve the service.
      </p>

      <h2>Accounts</h2>
      <ul>
        <li>Keep your credentials confidential; you are responsible for activity under your account.</li>
        <li>Accounts are provisioned per person with a role (for example admin, dispatcher, driver); do not share logins.</li>
        <li>Notify us promptly of any unauthorized use.</li>
      </ul>

      <h2>Your data</h2>
      <ul>
        <li>The carrier owns its operational data. We claim no rights to it beyond what is needed to run the service.</li>
        <li>You are responsible for the accuracy and lawfulness of the data you enter, upload, or forward into Truxon.</li>
        <li>On termination, the carrier may export its data; we will delete it on request, subject to legal retention requirements.</li>
      </ul>

      <h2>Acceptable use</h2>
      <ul>
        <li>No attempts to breach, probe, or overload the service or access another company's data.</li>
        <li>No unlawful content or use, and no uploading of malicious code.</li>
        <li>AI outputs (for example extracted document fields or assistant answers) are aids, not professional advice — review them before acting; you remain responsible for business decisions, filings, and invoices.</li>
      </ul>

      <h2>Third-party integrations</h2>
      <p>
        Optional integrations (for example QuickBooks Online) connect Truxon to your accounts with third parties
        under those parties' own terms. You authorize Truxon to exchange data with the integration on your behalf
        while it is connected; you may disconnect at any time.
      </p>

      <h2>Availability and disclaimers</h2>
      <p>
        We work to keep Truxon available and your data safe (including monitored, restore-tested backups), but the
        service is provided "as is" without warranties of any kind. We do not warrant uninterrupted or error-free
        operation.
      </p>

      <h2>Limitation of liability</h2>
      <p>
        To the maximum extent permitted by law, Truxon and its operators are not liable for indirect, incidental,
        special, or consequential damages, or for lost profits, revenue, or data, arising from use of the service.
        Our total liability for any claim is limited to the amounts paid for the service in the twelve months
        before the claim arose.
      </p>

      <h2>Termination</h2>
      <p>
        Either party may terminate use of the service. We may suspend accounts that violate these terms. Sections
        concerning data ownership, disclaimers, and liability survive termination.
      </p>

      <h2>Changes and contact</h2>
      <p>
        We may update these terms; material changes will be noted here with a new date, and continued use after a
        change constitutes acceptance. Questions:&nbsp;
        <a className="text-brand hover:underline" href="mailto:sales@truxon.com">sales@truxon.com</a>.
      </p>
    </LegalShell>
  )
}
