import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/cash_lens"
import topbar from "../vendor/topbar"
import Chart from 'chart.js/auto';
import DOMPurify from 'dompurify';

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longTimeout: 60000,
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    DirectoryUpload: {
      mounted() {
        this.el.addEventListener("change", e => {
          const liveInput = document.querySelector('input[data-phx-hook="Phoenix.LiveFileUpload"]');
          if (!liveInput) return;
          const dt = new DataTransfer();
          Array.from(e.target.files).forEach(file => {
            if (file.name.toLowerCase().endsWith('.csv')) { dt.items.add(file); }
          });
          liveInput.files = dt.files;
          liveInput.dispatchEvent(new Event('change', {bubbles: true}));
        });
      }
    },
    InfiniteScroll: {
      mounted() {
        this.observer = new IntersectionObserver(entries => {
          const entry = entries[0];
          if (entry.isIntersecting) { this.pushEvent("load-more"); }
        });
        this.observer.observe(this.el);
      },
      destroyed() { if (this.observer) this.observer.disconnect(); }
    },
    CategoryAutocomplete: {
      mounted() {
        this.init();
      },
      updated() {
        this.init();
      },
      init() {
        const input = this.el.querySelector('input');
        const dropdown = this.el.querySelector('.dropdown-content');
        const list = dropdown.querySelector('ul');
        const txId = this.el.getAttribute('data-transaction-id');
        const categories = JSON.parse(this.el.getAttribute('data-categories'));

        const renderOptions = (filter = "") => {
          const newOpt = list.querySelector('.new-option');
          list.innerHTML = '';
          list.appendChild(newOpt);
          const newLabel = filter ? `+ Criar "${filter}"...` : "+ Nova Categoria...";
          newOpt.querySelector('span').innerText = newLabel;
          newOpt.onclick = () => {
            this.pushEvent("open_quick_category", { name: filter, id: txId });
            dropdown.classList.add('hidden');
          };
          const filtered = categories
            .filter(c => c.name.toLowerCase().includes(filter.toLowerCase()))
            .sort((a, b) => a.name.localeCompare(b.name));
          filtered.forEach(cat => {
            const li = document.createElement('li');
            const btn = document.createElement('button');
            btn.type = "button";
            btn.innerText = cat.name;
            btn.className = "text-[10px] py-1 font-medium";
            btn.onclick = () => {
              this.pushEvent("update_category", { transaction_id: txId, category_id: cat.id });
              dropdown.classList.add('hidden');
              input.value = "";
              input.placeholder = cat.name;
            };
            li.appendChild(btn);
            list.appendChild(li);
          });
        };
        input.addEventListener("focus", () => { dropdown.classList.remove('hidden'); renderOptions(input.value); });
        input.addEventListener("input", (e) => { renderOptions(e.target.value); });
        
        // Remove existing listener if any to avoid duplicates
        if (this.clickHandler) document.removeEventListener("click", this.clickHandler);
        this.clickHandler = (e) => { if (!this.el.contains(e.target)) { dropdown.classList.add('hidden'); input.value = ""; } };
        document.addEventListener("click", this.clickHandler);
      }
    },
    MarkdownRenderer: {
      mounted() { this.render(); },
      updated() { this.render(); },
      render() {
        // TODO: Implement a robust Markdown-to-HTML renderer (e.g., using a library like marked or shiki)
        const raw = this.el.getAttribute("data-content") || "";
        this.el.innerHTML = DOMPurify.sanitize(raw);
      }
    }
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()
window.liveSocket = liveSocket

// Chart Initialization
window.addEventListener("load", () => {
  const ctx = document.getElementById('balanceChart');
  if (ctx) {
    const rawData = ctx.getAttribute('data-history');
    if (rawData) {
      const history = JSON.parse(rawData);
      const labels = history.map(item => `${item.month}/${item.year}`);
      
      new Chart(ctx, {
        type: 'line',
        data: {
          labels: labels,
          datasets: [
            {
              label: 'Saldo Final (Acumulado)',
              data: history.map(item => item.final_balance),
              borderColor: 'rgb(59, 130, 246)', // Blue
              backgroundColor: 'rgba(59, 130, 246, 0.1)',
              borderWidth: 3,
              fill: true,
              tension: 0.4
            },
            {
              label: 'Entradas',
              data: history.map(item => item.income),
              borderColor: 'rgb(34, 197, 94)', // Green
              borderWidth: 2,
              borderDash: [5, 5],
              tension: 0.4
            },
            {
              label: 'Saídas',
              data: history.map(item => item.expenses),
              borderColor: 'rgb(239, 68, 68)', // Red
              borderWidth: 2,
              borderDash: [5, 5],
              tension: 0.4
            },
            {
              label: 'Balanço do Mês (Líquido)',
              type: 'bar',
              data: history.map(item => item.balance),
              backgroundColor: history.map(item => item.balance >= 0 ? 'rgba(34, 197, 94, 0.5)' : 'rgba(239, 68, 68, 0.5)'),
              borderRadius: 4
            }
          ]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            tooltip: {
              callbacks: {
                label: function(context) {
                  let label = context.dataset.label || '';
                  if (label) label += ': ';
                  if (context.parsed.y !== null) {
                    label += new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(context.parsed.y);
                  }
                  return label;
                }
              }
            }
          },
          scales: {
            y: {
              ticks: {
                callback: function(value) {
                  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL', maximumSignificantDigits: 3 }).format(value);
                }
              }
            }
          }
        }
      });
    }
  }

  const initCategoryChart = (canvasId) => {
    const el = document.getElementById(canvasId);
    if (!el) return;

    const rawData = el.getAttribute('data-categories');
    if (!rawData) return;

    const history = JSON.parse(rawData);
    if (history.length === 0) return;

    const allCategories = [...new Set(history.flatMap(h => h.categories.map(c => c.name)))].sort();
    const labels = history.map(h => `${h.month}/${h.year}`);
    
    const colors = [
      'rgba(59, 130, 246, 0.7)', 'rgba(16, 185, 129, 0.7)', 'rgba(245, 158, 11, 0.7)', 
      'rgba(239, 68, 68, 0.7)', 'rgba(139, 92, 246, 0.7)', 'rgba(236, 72, 153, 0.7)', 
      'rgba(20, 184, 166, 0.7)', 'rgba(249, 115, 22, 0.7)', 'rgba(107, 114, 128, 0.7)', 
      'rgba(14, 165, 233, 0.7)', 'rgba(168, 85, 247, 0.7)', 'rgba(217, 70, 239, 0.7)', 
      'rgba(244, 63, 94, 0.7)', 'rgba(101, 163, 13, 0.7)', 'rgba(234, 179, 8, 0.7)', 
      'rgba(2, 132, 199, 0.7)', 'rgba(71, 85, 105, 0.7)', 'rgba(190, 18, 60, 0.7)', 
      'rgba(15, 118, 110, 0.7)', 'rgba(67, 56, 202, 0.7)'
    ];

    const datasets = allCategories.map((catName, index) => {
      const color = colors[index % colors.length];
      return {
        label: catName,
        data: history.map(h => {
          const found = h.categories.filter(c => c.name === catName);
          return found.reduce((acc, c) => acc + c.total, 0);
        }),
        borderColor: color,
        backgroundColor: color.replace('0.7', '0.1'),
        borderWidth: 2,
        pointRadius: 3,
        tension: 0.3,
        fill: false
      };
    });

    new Chart(el, {
      type: 'line',
      data: { labels: labels, datasets: datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { position: 'bottom', labels: { boxWidth: 12, padding: 15, font: { size: 10, weight: 'bold' } } },
          tooltip: {
            itemSort: (a, b) => b.raw - a.raw,
            filter: (item) => item.raw > 0,
            callbacks: {
              label: (context) => {
                const val = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(context.parsed.y);
                return `${context.dataset.label}: ${val}`;
              }
            }
          }
        },
        scales: {
          x: { grid: { display: false } },
          y: { 
            beginAtZero: true,
            ticks: {
              callback: (value) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL', maximumSignificantDigits: 3 }).format(value)
            }
          }
        }
      }
    });
  };

  initCategoryChart('fixedChart');
  initCategoryChart('variableChart');
});
