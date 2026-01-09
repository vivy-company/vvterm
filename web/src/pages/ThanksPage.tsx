import React from "react";
import { CheckCircle, Smartphone, RefreshCw, MessageCircle } from "lucide-react";

export function ThanksPage() {
  return (
    <div className="min-h-screen flex flex-col items-center justify-center px-6 py-20 bg-[radial-gradient(ellipse_80%_50%_at_50%_-20%,rgba(52,199,89,0.1),transparent)]">
      <div className="max-w-[700px] mx-auto">
        {/* Header */}
        <div className="text-center mb-12">
          <div className="relative inline-block mb-6">
            <img src="/logo.png" alt="VVTerm" className="w-24 h-24 rounded-[22px]" />
            <div className="absolute -bottom-1 -right-1 w-8 h-8 rounded-full bg-green-500 flex items-center justify-center">
              <CheckCircle size={18} className="text-white" />
            </div>
          </div>
          <h1 className="text-5xl font-semibold tracking-tight mb-4">Thank You!</h1>
          <p className="text-xl text-[#86868b]">
            Welcome to VVTerm Pro. Your purchase is complete.
          </p>
        </div>

        {/* Steps */}
        <div className="bg-white/[0.03] border border-white/8 rounded-3xl p-8 mb-8">
          <h2 className="text-xl font-semibold mb-6">You're all set</h2>
          <div className="space-y-6">
            <div className="flex gap-4">
              <div className="w-10 h-10 rounded-xl bg-blue-500/20 flex items-center justify-center flex-shrink-0">
                <Smartphone size={20} className="text-blue-500" />
              </div>
              <div>
                <h3 className="font-medium mb-1">Open VVTerm</h3>
                <p className="text-[#86868b] text-sm">Your Pro features are automatically unlocked on all devices signed in with your Apple ID.</p>
              </div>
            </div>
            <div className="flex gap-4">
              <div className="w-10 h-10 rounded-xl bg-green-500/20 flex items-center justify-center flex-shrink-0">
                <RefreshCw size={20} className="text-green-500" />
              </div>
              <div>
                <h3 className="font-medium mb-1">Sync across devices</h3>
                <p className="text-[#86868b] text-sm">Add unlimited servers and workspaces. They'll sync via iCloud to all your devices.</p>
              </div>
            </div>
          </div>
        </div>

        {/* Actions */}
        <div className="flex gap-4 mb-8">
          <a
            href="https://discord.gg/zemMZtrkSb"
            target="_blank"
            rel="noopener noreferrer"
            className="flex-1 inline-flex items-center justify-center gap-2 px-6 py-3 text-[17px] font-normal border border-white/20 text-white rounded-full hover:bg-white/5 transition-all duration-200"
          >
            <MessageCircle size={18} />
            Join Discord
          </a>
        </div>

        {/* Support */}
        <p className="text-center text-sm text-[#86868b]">
          Need help? Contact us at <a href="mailto:vvterm@vivy.company" className="text-blue-500 hover:underline">vvterm@vivy.company</a>
        </p>

        <div className="mt-12 text-center">
          <a href="/" className="text-blue-500 hover:underline">← Back to Home</a>
        </div>
      </div>
    </div>
  );
}
