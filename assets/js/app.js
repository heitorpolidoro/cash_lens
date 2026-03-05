// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/cash_lens"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    DirectoryUpload: {
      mounted() {
        this.el.addEventListener("change", e => {
          // Find the real Phoenix live file input by its unique attribute
          const liveInput = document.querySelector('input[data-phx-hook="Phoenix.LiveFileUpload"]');
          
          if (!liveInput) {
            console.error("Phoenix live file input not found!");
            return;
          }
          
          const dt = new DataTransfer();
          Array.from(e.target.files).forEach(file => {
            if (file.name.toLowerCase().endsWith('.csv')) {
              dt.items.add(file);
            }
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
          if (entry.isIntersecting) {
            this.pushEvent("load-more");
          }
        });
        this.observer.observe(this.el);
      },
      destroyed() {
        if (this.observer) this.observer.disconnect();
      }
    },
    CategoryAutocomplete: {
      mounted() {
        const input = this.el.querySelector('input');
        const dropdown = this.el.querySelector('.dropdown-content');
        const list = dropdown.querySelector('ul');
        const txId = this.el.getAttribute('data-transaction-id');
        const categories = JSON.parse(this.el.getAttribute('data-categories'));

        const renderOptions = (filter = "") => {
          // Keep only the "New Category" option initially
          const newOpt = list.querySelector('.new-option');
          list.innerHTML = '';
          list.appendChild(newOpt);
          
          // Update the "New Category" text
          const newLabel = filter ? `+ Criar "${filter}"...` : "+ Nova Categoria...";
          newOpt.querySelector('span').innerText = newLabel;
          newOpt.onclick = () => {
            this.pushEvent("open_quick_category", { name: filter, id: txId });
            dropdown.classList.add('hidden');
          };

          // Filter and sort categories
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

        input.addEventListener("focus", () => {
          dropdown.classList.remove('hidden');
          renderOptions(input.value);
        });

        input.addEventListener("input", (e) => {
          renderOptions(e.target.value);
        });

        // Close when clicking outside
        document.addEventListener("click", (e) => {
          if (!this.el.contains(e.target)) {
            dropdown.classList.add('hidden');
            input.value = "";
          }
        });
      }
    }
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// Chart.js Setup for Dashboard
import Chart from 'chart.js/auto';

document.addEventListener("DOMContentLoaded", () => {
  const ctx = document.getElementById('balanceChart');
  if (ctx) {
    const rawData = ctx.getAttribute('data-history');
    if (rawData) {
      const history = JSON.parse(rawData);
      
      const labels = history.map(item => `${item.month}/${item.year}`);
      const balanceData = history.map(item => parseFloat(item.balance));
      const incomeData = history.map(item => parseFloat(item.income));
      const expensesData = history.map(item => parseFloat(item.expenses));
      const finalBalanceData = history.map(item => parseFloat(item.final_balance));

      new Chart(ctx, {
        type: 'line',
        data: {
          labels: labels,
          datasets: [
            {
              label: 'Saldo Final (Acumulado)',
              data: finalBalanceData,
              borderColor: 'rgb(59, 130, 246)', // Blue
              backgroundColor: 'rgba(59, 130, 246, 0.1)',
              borderWidth: 3,
              fill: true,
              tension: 0.4
            },
            {
              label: 'Entradas',
              data: incomeData,
              borderColor: 'rgb(34, 197, 94)', // Green
              borderWidth: 2,
              borderDash: [5, 5],
              tension: 0.4
            },
            {
              label: 'Saídas',
              data: expensesData,
              borderColor: 'rgb(239, 68, 68)', // Red
              borderWidth: 2,
              borderDash: [5, 5],
              tension: 0.4
            },
            {
              label: 'Balanço do Mês (Líquido)',
              type: 'bar',
              data: balanceData,
              backgroundColor: balanceData.map(val => val >= 0 ? 'rgba(34, 197, 94, 0.5)' : 'rgba(239, 68, 68, 0.5)'),
              borderRadius: 4
            }
          ]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: {
            mode: 'index',
            intersect: false,
          },
          plugins: {
            tooltip: {
              callbacks: {
                label: function(context) {
                  let label = context.dataset.label || '';
                  if (label) { label += ': '; }
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
                callback: function(value, index, values) {
                  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL', maximumSignificantDigits: 3 }).format(value);
                }
              }
            }
          }
        }
      });
    }
  }

  const catCtx = document.getElementById('categoryChart');
  if (catCtx) {
    const rawData = catCtx.getAttribute('data-categories');
    if (rawData) {
      const history = JSON.parse(rawData);
      
      // 1. Get all unique categories across all months
      const allCategories = [...new Set(history.flatMap(h => h.categories.map(c => c.name)))];
      
      // 2. Map labels (months)
      const labels = history.map(h => `${h.month}/${h.year}`);
      
      // 3. Prepare datasets (one per category)
      const colors = [
        'rgba(59, 130, 246, 0.7)',  // Blue
        'rgba(16, 185, 129, 0.7)',  // Green
        'rgba(245, 158, 11, 0.7)',  // Amber
        'rgba(239, 68, 68, 0.7)',   // Red
        'rgba(139, 92, 246, 0.7)',  // Violet
        'rgba(236, 72, 153, 0.7)',  // Pink
        'rgba(20, 184, 166, 0.7)',  // Teal
        'rgba(249, 115, 22, 0.7)',  // Orange
        'rgba(107, 114, 128, 0.7)', // Gray
        'rgba(14, 165, 233, 0.7)',  // Sky
        'rgba(168, 85, 247, 0.7)',  // Purple
        'rgba(217, 70, 239, 0.7)',  // Fuchsia
        'rgba(244, 63, 94, 0.7)',   // Rose
        'rgba(101, 163, 13, 0.7)',  // Lime
        'rgba(234, 179, 8, 0.7)',   // Yellow
        'rgba(2, 132, 199, 0.7)',   // Light Blue
        'rgba(71, 85, 105, 0.7)',   // Slate
        'rgba(190, 18, 60, 0.7)',   // Crimson
        'rgba(15, 118, 110, 0.7)',  // Dark Teal
        'rgba(67, 56, 202, 0.7)'    // Indigo
      ];

      const datasets = allCategories.map((catName, index) => {
        const color = colors[index % colors.length];
        return {
          label: catName,
          data: history.map(h => {
            const cat = h.categories.find(c => c.name === catName);
            return cat ? parseFloat(cat.total) : 0;
          }),
          borderColor: color,
          backgroundColor: color.replace('0.7', '0.1'),
          borderWidth: 2,
          pointRadius: 3,
          pointHoverRadius: 6,
          tension: 0.3,
          fill: false
        };
      });

      new Chart(catCtx, {
        type: 'line',
        data: {
          labels: labels,
          datasets: datasets
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: {
            mode: 'index',
            intersect: false,
          },
          plugins: {
            legend: { 
              position: 'bottom',
              labels: {
                boxWidth: 12,
                padding: 15,
                font: { size: 10, weight: 'bold' }
              }
            },
            tooltip: {
              filter: function(tooltipItem) {
                return tooltipItem.raw > 0;
              },
              callbacks: {
                label: function(context) {
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
});

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

