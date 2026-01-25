import React from "react";

export function RefundPage() {
  return (
    <div className="min-h-screen px-6 py-20">
      <div className="max-w-[800px] mx-auto">
        <a href="/" className="inline-block mb-8">
          <img src="/logo.png" alt="VVTerm" className="w-12 h-12 rounded-xl" />
        </a>
        <h1 className="text-4xl font-semibold tracking-tight mb-2">Refund Policy</h1>
        <p className="text-[#86868b] mb-8">Last updated: January 15, 2026</p>

        <div className="prose prose-invert max-w-none space-y-6 text-[#86868b]">
          <section>
            <h2 className="text-xl font-semibold text-white mb-3">Refunds for App Store Purchases</h2>
            <p>
              VVTerm Pro is sold through Apple’s App Store. Apple handles billing and refunds, and eligibility is
              determined by Apple’s policies.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">How to Request a Refund</h2>
            <p>To request a refund, use Apple’s official process:</p>
            <ol className="list-decimal list-inside space-y-2 mt-2">
              <li>Go to <a href="https://reportaproblem.apple.com" className="text-blue-500 hover:underline">reportaproblem.apple.com</a></li>
              <li>Sign in with your Apple ID</li>
              <li>Find your VVTerm Pro purchase</li>
              <li>Select "Request a refund" and follow the prompts</li>
            </ol>
            <p className="mt-4">
              We’re unable to issue refunds directly, but if you’re having trouble using the app,
              contact us and we’ll do our best to help.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">Subscription Cancellation</h2>
            <p>
              If you subscribed to VVTerm Pro Monthly or Yearly, you can cancel at any time:
            </p>
            <ol className="list-decimal list-inside space-y-2 mt-2">
              <li>Open Settings on your iPhone/iPad or System Settings on Mac</li>
              <li>Tap your Apple ID → Subscriptions</li>
              <li>Find VVTerm and tap "Cancel Subscription"</li>
            </ol>
            <p className="mt-4">Upon cancellation:</p>
            <ul className="list-disc list-inside space-y-1 mt-2">
              <li>You'll retain Pro access until the end of your current billing period</li>
              <li>No further charges will be made</li>
              <li>Pro features will be disabled after the period ends</li>
              <li>Your servers and workspaces will remain, but free tier limits will apply</li>
            </ul>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">Lifetime Purchases</h2>
            <p>
              Lifetime Pro purchases are one-time and do not require cancellation.
              Refunds are handled by Apple using the same process above.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">Contact Us</h2>
            <p>
              Questions or technical issues? Contact us at:{" "}
              <a href="mailto:vvterm@vivy.company" className="text-blue-500 hover:underline">vvterm@vivy.company</a>
            </p>
          </section>
        </div>

        <div className="mt-12 pt-8 border-t border-white/8">
          <a href="/" className="text-blue-500 hover:underline">← Back to Home</a>
        </div>
      </div>
    </div>
  );
}
