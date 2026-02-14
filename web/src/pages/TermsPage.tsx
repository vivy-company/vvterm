import React from "react";

export function TermsPage() {
  return (
    <div className="min-h-screen px-6 py-20">
      <div className="max-w-[800px] mx-auto">
        <a href="/" className="inline-block mb-8">
          <img src="/logo.png" alt="VVTerm" className="w-12 h-12 rounded-xl" />
        </a>
        <h1 className="text-4xl font-semibold tracking-tight mb-2">Terms of Use (EULA)</h1>
        <p className="text-[#86868b] mb-8">Last updated: February 14, 2026</p>

        <div className="prose prose-invert max-w-none space-y-6 text-[#86868b]">
          <section>
            <h2 className="text-xl font-semibold text-white mb-3">1. Acceptance of Terms</h2>
            <p>
              By downloading, installing, or using VVTerm ("the App"), you agree to be bound by these Terms of Use (EULA).
              If you do not agree to these terms, do not use the App.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">2. License Grant</h2>
            <p>
              Vivy Technologies Co., Limited grants you a limited, non-exclusive, non-transferable license to use VVTerm
              for personal or commercial purposes, subject to these terms.
            </p>
            <p className="mt-3">
              These Terms apply to official VVTerm binaries distributed through Apple's App Store.
              Source code published at{" "}
              <a href="https://github.com/vivy-company/vvterm" className="text-blue-500 hover:underline" target="_blank" rel="noopener noreferrer">
                github.com/vivy-company/vvterm
              </a>{" "}
              is licensed separately under GPL-3.0.
            </p>
            <h3 className="text-lg font-medium text-white mb-2 mt-4">Free Version</h3>
            <p>
              The free version of VVTerm may be used without charge, subject to the following limitations:
              1 workspace, 3 servers, and 1 simultaneous connection.
            </p>
            <h3 className="text-lg font-medium text-white mb-2 mt-4">VVTerm Pro</h3>
            <p>
              VVTerm Pro requires a valid in-app purchase through the App Store. Pro unlocks unlimited workspaces,
              servers, and simultaneous connections.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">3. Restrictions</h2>
            <p>You may not:</p>
            <ul className="list-disc list-inside space-y-1 mt-2">
              <li>Reverse engineer, decompile, or disassemble the App</li>
              <li>Remove or alter any proprietary notices or labels</li>
              <li>Share or distribute your App Store purchase with others</li>
              <li>Use the App for any unlawful purpose</li>
              <li>Attempt to gain unauthorized access to remote servers</li>
            </ul>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">4. SSH Connections</h2>
            <p>
              VVTerm facilitates SSH connections to servers you configure. You are solely responsible for:
            </p>
            <ul className="list-disc list-inside space-y-1 mt-2">
              <li>Ensuring you have authorization to access the servers you connect to</li>
              <li>Safeguarding your credentials and SSH keys</li>
              <li>Any actions performed through SSH connections made via the App</li>
            </ul>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">5. iCloud Sync</h2>
            <p>
              Server configurations may be synced via Apple iCloud. Your use of iCloud is subject to Apple's terms of service.
              We are not responsible for iCloud availability or data loss due to iCloud issues.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">6. Disclaimer of Warranties</h2>
            <p>
              THE APP IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
              WE DO NOT WARRANT THAT THE APP WILL BE UNINTERRUPTED, ERROR-FREE, OR SECURE.
              SSH CONNECTIONS ARE MADE DIRECTLY BETWEEN YOUR DEVICE AND REMOTE SERVERS; WE DO NOT PROXY OR INSPECT THIS TRAFFIC.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">7. Limitation of Liability</h2>
            <p>
              IN NO EVENT SHALL VIVY TECHNOLOGIES CO., LIMITED BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL,
              CONSEQUENTIAL, OR PUNITIVE DAMAGES ARISING OUT OF YOUR USE OF THE APP, INCLUDING BUT NOT LIMITED TO
              DATA LOSS, UNAUTHORIZED ACCESS, OR SERVER DOWNTIME.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">8. Termination</h2>
            <p>
              Your license to use the App terminates automatically if you violate these terms.
              Apple may also terminate your access through the App Store.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">9. Governing Law</h2>
            <p>
              These terms shall be governed by the laws of Hong Kong SAR, without regard to its conflict of law provisions.
            </p>
          </section>

          <section>
            <h2 className="text-xl font-semibold text-white mb-3">10. Contact</h2>
            <p>
              For questions about these Terms, contact us at:{" "}
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
