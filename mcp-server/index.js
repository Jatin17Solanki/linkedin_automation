const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");

const WEBHOOK_URL = "https://35.224.120.172.nip.io/webhook/parse-job";

const server = new McpServer({
  name: "linkedin-job-parser",
  version: "1.0.0",
});

server.tool(
  "parse-linkedin-job",
  "Parse a LinkedIn job posting URL and return structured details including title, company, location, experience requirements, and job description.",
  {
    url: z
      .string()
      .describe(
        'LinkedIn job URL, e.g. "https://linkedin.com/jobs/view/4370408479"'
      ),
  },
  async ({ url }) => {
    try {
      const response = await fetch(WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url }),
      });

      if (!response.ok) {
        return {
          content: [
            {
              type: "text",
              text: "Webhook returned HTTP " + response.status + ": " + (await response.text()),
            },
          ],
          isError: true,
        };
      }

      const data = await response.json();

      if (!data.success) {
        return {
          content: [
            {
              type: "text",
              text: "Parse failed: " + (data.error || "Unknown error"),
            },
          ],
          isError: true,
        };
      }

      const lines = [
        "Title: " + data.title,
        "Company: " + data.company,
        "Location: " + data.location,
        "Experience: " + (data.experience || "Not specified"),
        "Seniority: " + (data.seniority_level || "Not specified"),
        "Apply URL: " + (data.apply_url || "N/A"),
        "Source: " + data.source_url,
        "",
        "Job Description:",
        data.job_description || "N/A",
      ];

      return {
        content: [{ type: "text", text: lines.join("\n") }],
      };
    } catch (err) {
      return {
        content: [
          {
            type: "text",
            text: "Failed to call webhook: " + err.message,
          },
        ],
        isError: true,
      };
    }
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main();
