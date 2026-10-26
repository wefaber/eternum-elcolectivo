import { motion } from "framer-motion";
import { FileText, Download, ExternalLink, Search } from "lucide-react";
import { fadeUp, fadeUpStagger, fadeUpItem } from "../lib/animations";

const papers = [
  {
    title: "Más allá del 1 al 10",
    subtitle: "Calibración semántica en encuestas",
    desc: "Por qué la escala numérica deforma aquello que intenta medir, y la Ley de Goodhart que aparece cuando optimizamos un sistema con esa métrica. Propone un modelo de calibración semántica en tres capas que interpreta cada respuesta desde el marco de referencia de quien la dio.",
    meta: "PDF · 4,2 MB · Eternum",
    href: "/papers/calibracion-semantica-encuestas.pdf",
    file: "mas-alla-del-1-al-10-calibracion-semantica.pdf",
  },
];

export function Papers() {
  return (
    <motion.section
      id="papers"
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, amount: 0.2 }}
      className="py-24 px-4 sm:px-6 lg:px-8 bg-mid/3"
    >
      <div className="max-w-6xl mx-auto">
        <motion.div variants={fadeUp} className="text-center mb-16">
          <h2 className="text-3xl sm:text-4xl font-bold text-text-primary mb-4">Papers</h2>
          <p className="text-text-secondary max-w-2xl mx-auto text-lg">
            Investigación abierta del colectivo. Lo que se publica acá queda disponible para leer,
            citar y discutir.
          </p>
        </motion.div>

        <motion.ul
          variants={fadeUpStagger}
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          className="max-w-4xl mx-auto space-y-4 list-none p-0 m-0"
        >
          {papers.map(({ title, subtitle, desc, meta, href, file }) => (
            <motion.li key={title} variants={fadeUpItem} className="group">
              <div className="flex flex-col gap-6 sm:flex-row sm:items-start sm:justify-between p-6 sm:p-7 rounded-2xl bg-surface-raised border border-border hover:border-border-strong transition-colors duration-300">
                <div className="flex items-start gap-4 min-w-0">
                  <div className="w-11 h-11 shrink-0 rounded-xl bg-badge-bg flex items-center justify-center">
                    <FileText className="w-5 h-5 text-mid" aria-hidden="true" />
                  </div>
                  <div className="min-w-0">
                    <h3 className="text-xl font-semibold text-text-primary leading-snug">
                      {title}
                    </h3>
                    <p className="text-sm text-text-secondary mt-0.5">{subtitle}</p>
                    <p className="text-sm text-text-secondary leading-relaxed mt-3">{desc}</p>
                    <p className="text-xs text-text-secondary mt-3 tabular-nums">{meta}</p>
                  </div>
                </div>
                <a
                  href={href}
                  download={file}
                  aria-label={`Descargar ${title} en PDF`}
                  className="w-full sm:w-auto shrink-0 sm:self-start inline-flex items-center justify-center gap-2 px-5 py-3 rounded-xl bg-bright text-text-on-accent text-sm font-medium hover:bg-bright/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-bright transition-colors duration-200 whitespace-nowrap"
                >
                  <Download className="w-4 h-4" aria-hidden="true" />
                  Descargar
                </a>
              </div>
            </motion.li>
          ))}
        </motion.ul>

        <motion.div variants={fadeUp} className="mt-12 text-center">
          <motion.a
            whileHover={{ scale: 1.02 }}
            whileTap={{ scale: 0.98 }}
            href="https://github.com/wefaber/eternum-elcolectivo"
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-2 px-6 py-3 rounded-xl border border-border text-text-primary hover:bg-mid/5 transition-colors duration-200"
          >
            <Search className="w-5 h-5" aria-hidden="true" />
            Explorar el repositorio
            <ExternalLink className="w-4 h-4" aria-hidden="true" />
          </motion.a>
        </motion.div>
      </div>
    </motion.section>
  );
}
