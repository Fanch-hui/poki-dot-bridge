import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Poki-Dot Bridge",
  description: "ChatGPT Sites MCP & iPhone Device Queue",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
