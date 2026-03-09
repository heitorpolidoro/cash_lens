import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/cash_lens"
import topbar from "../vendor/topbar"

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
          const files = e.target.files;
          const dataTransfer = new DataTransfer();
          for (let i = 0; i < files.length; i++) {
            dataTransfer.items.add(files[i]);
          }
          liveInput.files = dataTransfer.files;
          liveInput.dispatchEvent(new Event("change", {bubbles: true}));
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
        input.addEventListener("focus", () => {
          dropdown.classList.remove('hidden');
          renderOptions(input.value);
        });
        input.addEventListener("input", (e) => {
          renderOptions(e.target.value);
        });
        document.addEventListener("click", (e) => {
          if (!this.el.contains(e.target)) {
            dropdown.classList.add('hidden');
            input.value = "";
          }
        });
      }
    },
    MarkdownRenderer: {
      mounted() { this.render(); },
      updated() { this.render(); },
      render() {
        const raw = this.el.getAttribute("data-content") || "";
        this.el.innerHTML = raw
          .replace(/### (.*$)/gm, '<h3 class="text-lg font-black mt-4 mb-2 text-secondary">$1</h3>')
          .replace(/\*\*(.*?)\*\*/g, '<strong class="font-black text-secondary">$1</strong>')
          .replace(/^\s*[\-\*] (.*$)/gm, '<div class="flex gap-2 ml-2 my-1"><span class="text-secondary">•</span><span>$1</span></div>')
          .replace(/\n\n/g, '<br/><br/>')
          .trim();
      }
    }
  }
})

liveSocket.connect()
window.liveSocket = liveSocket
