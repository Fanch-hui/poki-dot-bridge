import { headers } from "next/headers";
import { AdminDashboard } from "@/components/AdminDashboard";
import { decodeSitesHeaderValue } from "@/server/auth";
import { resolveRuntimeEnv } from "@/server/env";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  const hdrs = await headers();
  const env = await resolveRuntimeEnv();
  const email = decodeSitesHeaderValue(hdrs.get("oai-authenticated-user-email"))?.toLowerCase() ?? null;
  const fullName = decodeSitesHeaderValue(hdrs.get("oai-authenticated-user-full-name")) ?? null;
  const allowlist = env.config.allowedOwnerEmails;

  const authorized =
    env.config.localDevAutoAuth ||
    (email !== null &&
      (allowlist.length > 0 ? allowlist.includes(email) : env.config.trustSitesIdentity));

  if (!authorized) {
    return (
      <main className="shell">
        <div className="card" style={{ maxWidth: 420, margin: "80px auto", textAlign: "center" }}>
          <h1 style={{ fontSize: 18, margin: "0 0 16px" }}>Poki-Dot Bridge</h1>
          <a className="btn" href="/signin-with-chatgpt" style={{ display: "inline-flex", alignItems: "center", textDecoration: "none" }}>
            Sign in with ChatGPT
          </a>
        </div>
      </main>
    );
  }

  return (
    <AdminDashboard
      actorLabel={fullName ?? email ?? "Local"}
      showSignOut={email !== null}
    />
  );
}
