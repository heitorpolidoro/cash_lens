// Scraper de histórico de compras do Mercado Livre usando Playwright
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { chromium } = require('../assets/node_modules/playwright');

// Helper to ask question in terminal
const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const question = (query) => new Promise((resolve) => rl.question(query, resolve));

async function main() {
  console.log("Iniciando navegador Chromium visível...");
  
  const browser = await chromium.launch({
    headless: false,
    channel: "chrome" // Tries to use local Chrome, falls back to Chromium
  });

  const outputDir = path.join(__dirname, '../statements');
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir);
  }

  const sessionPath = path.join(outputDir, 'mercado_livre_session.json');
  let contextOptions = {
    viewport: { width: 1280, height: 800 }
  };

  // Restore session cookies if file exists
  if (fs.existsSync(sessionPath)) {
    console.log("Sessão anterior detectada. Restaurando cookies...");
    contextOptions.storageState = sessionPath;
  } else {
    console.log("Nenhuma sessão salva encontrada. Novo login será necessário.");
  }

  const context = await browser.newContext(contextOptions);
  const page = await context.newPage();

  console.log("Navegando para o Mercado Livre...");
  await page.goto("https://myaccount.mercadolivre.com.br/purchases/list");

  // Load existing purchases if they exist to support incremental appending
  const outputPath = path.join(outputDir, 'mercado_livre_compras.json');
  let existingPurchases = [];
  if (fs.existsSync(outputPath)) {
    try {
      existingPurchases = JSON.parse(fs.readFileSync(outputPath, 'utf-8'));
      console.log(`Carregadas ${existingPurchases.length} compras existentes do arquivo JSON.`);
    } catch (e) {
      console.log("Aviso: Não foi possível ler o arquivo JSON existente, iniciando um novo.");
    }
  }

  console.log("\n======================================================================");
  console.log("INSTRUÇÕES DE USO:");
  console.log("1. Caso já esteja logado (cookies restaurados), apenas aguarde a página carregar.");
  console.log("2. Se não estiver logado, faça o login e resolva o 2FA normalmente.");
  console.log("3. Vá para a lista geral de 'Minhas Compras' ou abra os detalhes de uma compra.");
  console.log("4. Quando estiver na página desejada:");
  console.log("   Volte aqui no terminal e pressione [ENTER] para capturar os dados.");
  console.log("======================================================================\n");

  await question("Pressione [ENTER] quando estiver na página que deseja extrair...");

  const currentUrl = page.url();
  console.log(`\nURL atual detectada: ${currentUrl}`);

  // Save current session state (cookies) to keep it fresh for next runs
  try {
    await context.storageState({ path: sessionPath });
    console.log("Sessão (cookies) atualizada e salva com sucesso.");
  } catch (err) {
    console.log("Aviso: Não foi possível salvar os cookies da sessão.");
  }

  let newPurchases = [];

  // Check if we are on a purchase details page
  const isDetailPage = await page.evaluate(() => {
    return !!document.querySelector('.detail-container') || 
           (window.location.href.includes('/purchases/') && window.location.href.includes('/detail')) ||
           (window.location.href.includes('/my_purchases/') && window.location.href.includes('/status'));
  });

  if (isDetailPage) {
    console.log("Página de Detalhe de Compra detectada! Extraindo dados...");
    
    // Auto-expand payment details if collapsed
    try {
      const expandBtn = await page.$('button.bf-ui-expandable__button');
      if (expandBtn) {
        const text = await expandBtn.innerText();
        const expanded = await expandBtn.getAttribute('aria-expanded');
        if (text.includes('Detalhes do pagamento') && expanded === 'false') {
          console.log("Expandindo detalhes do pagamento...");
          await expandBtn.click();
          await page.waitForTimeout(1000); // wait for animation/rendering
        }
      }
    } catch (e) {
      console.log("Aviso: Não foi possível expandir detalhes do pagamento automaticamente:", e.message);
    }
    
    const details = await page.evaluate(() => {
      // Extract date and order ID from subtitle
      const subtitleEl = document.querySelector('.bf-ui-ticket__subtitle');
      const subtitleText = subtitleEl ? subtitleEl.innerText : '';
      
      let dateStr = 'Data não encontrada';
      let mainOrderId = '';
      
      if (subtitleText.includes('|')) {
        const parts = subtitleText.split('|');
        dateStr = parts[0].trim();
        const idMatch = parts[1].match(/#\s*(\d+)/);
        if (idMatch) {
          mainOrderId = idMatch[1];
        }
      } else {
        const idMatch = subtitleText.match(/#\s*(\d+)/);
        if (idMatch) {
          mainOrderId = idMatch[1];
        }
      }

      // Extract product titles
      const titleEls = Array.from(document.querySelectorAll('.bf-ui-row-with-ellipsis__title'));
      const titles = titleEls.map(el => el.innerText.trim()).filter(t => t !== '');
      const title = titles.join(' + ') || 'Produto Mercado Livre';

      // Helper to make payment objects have unique orderIds if they are identical
      const makeUniqueOrderIds = (payments) => {
        const seen = {};
        return payments.map(p => {
          if (seen[p.orderId]) {
            seen[p.orderId]++;
            return { ...p, orderId: `${p.orderId}-p${seen[p.orderId]}` };
          } else {
            seen[p.orderId] = 1;
            return p;
          }
        });
      };

      // 1. Check if there are split/multiple payments in the details section
      // In Mercado Livre, these details are inside cards under "Pagamentos"
      const detailRows = Array.from(document.querySelectorAll('.bf-ui-detail-row'));
      const splitPayments = [];

      for (const row of detailRows) {
        const priceMeta = row.querySelector('meta[itemprop="price"]');
        const secondaryTitles = Array.from(row.querySelectorAll('[data-testid^="detail-row-secondary-title-"], .bf-ui-detail-row__secondary-title'));
        const secondaryText = secondaryTitles.map(el => el.innerText).join(' | ');

        if (priceMeta && (secondaryText.includes('#') || secondaryText.includes('Pagamento'))) {
          const priceStr = priceMeta.content.replace('null', ',');
          const idMatch = secondaryText.match(/#\s*(\d+)/) || secondaryText.match(/número\s*(\d+)/i);
          const paymentId = idMatch ? idMatch[1] : '';
          
          if (paymentId && priceStr !== '0,00') {
            splitPayments.push({
              orderId: paymentId,
              dateStr,
              priceStr,
              title
            });
          }
        }
      }

      if (splitPayments.length > 0) {
        return makeUniqueOrderIds(splitPayments);
      }

      // 2. Fallback to ticket rows if payments_row exists
      const paymentRows = Array.from(document.querySelectorAll('[id^="payments_row_"]'));
      if (paymentRows.length > 0) {
        const ticketPayments = [];
        for (const row of paymentRows) {
          let priceStr = '0,00';
          const priceMeta = row.querySelector('meta[itemprop="price"]');
          if (priceMeta && priceMeta.content) {
            priceStr = priceMeta.content.replace('null', ',');
          } else {
            const priceEl = row.querySelector('.bf-ui-rich-price');
            if (priceEl) {
              const match = priceEl.innerText.match(/R\$\s*([\d.]+,\d{2})/);
              if (match) priceStr = match[1];
            }
          }

          const cardText = row.innerText || '';
          const matchNum = cardText.match(/#\s*(\d+)/);
          const orderId = matchNum ? matchNum[1] : mainOrderId;

          if (priceStr !== '0,00') {
            ticketPayments.push({ orderId, dateStr, priceStr, title });
          }
        }

        if (ticketPayments.length > 0) {
          return makeUniqueOrderIds(ticketPayments);
        }
      }

      // 3. Fallback to single payment / total row
      const totalRow = document.querySelector('[id^="total_row_"]');
      let priceStr = '0,00';
      if (totalRow) {
        const priceMeta = totalRow.querySelector('meta[itemprop="price"]');
        if (priceMeta && priceMeta.content) {
          priceStr = priceMeta.content.replace('null', ',');
        } else {
          const priceEl = totalRow.querySelector('.bf-ui-rich-price');
          if (priceEl) {
            const match = priceEl.innerText.match(/R\$\s*([\d.]+,\d{2})/);
            if (match) priceStr = match[1];
          }
        }
      }
      return [{ orderId: mainOrderId, dateStr, priceStr, title }];
    });

    if (details && details.length > 0) {
      console.log(`\n✅ Compra(s) extraída(s) com sucesso:`);
      for (const d of details) {
        console.log(`   - ID: ${d.orderId}`);
        console.log(`   - Data: ${d.dateStr}`);
        console.log(`   - Valor: R$ ${d.priceStr}`);
        console.log(`   - Item(s): ${d.title}`);
        
        newPurchases.push({
          orderId: d.orderId,
          dateStr: d.dateStr,
          priceStr: d.priceStr,
          title: d.title,
          url: currentUrl
        });
      }
    } else {
      console.log("❌ Erro: Não foi possível obter detalhes das transações.");
    }

  } else {
    // We are on the general purchases list page
    console.log("Página de Lista de Compras detectada.");
    const mode = await question("Deseja extrair apenas a página atual (a) ou avançar páginas automaticamente (t)? [a/t]: ");
    const autoPage = mode.trim().toLowerCase() === 't';

    let pageCount = 1;
    let hasNextPage = true;

    while (hasNextPage) {
      console.log(`Extraindo dados da página ${pageCount}...`);
      await page.waitForTimeout(2000);

      const pagePurchases = await page.evaluate(() => {
        const results = [];
        const links = Array.from(document.querySelectorAll('a'));

        for (const link of links) {
          const href = link.href || '';
          
          const isPurchaseLink = (href.includes('/my_purchases/') && href.includes('/status')) || 
                                 (href.includes('/purchases/') && href.includes('/detail'));
          
          if (isPurchaseLink) {
            const purchaseIdMatch = href.match(/\/my_purchases\/(\d+)\/status/) || href.match(/\/purchases\/(?:pack\/)?(\d+)\/detail/);
            const purchaseId = purchaseIdMatch ? purchaseIdMatch[1] : '';

            const orderIdMatch = href.match(/[?&]orderId=(\d+)/);
            const orderId = orderIdMatch ? orderIdMatch[1] : '';

            const packIdMatch = href.match(/[?&]packId=(\d+)/);
            const packId = packIdMatch ? packIdMatch[1] : '';

            const finalId = orderId || packId || purchaseId;

            if (finalId) {
              const card = link.closest('.bf-ui-card') || 
                           link.closest('[class*="card"]') || 
                           link.closest('li') || 
                           link;

              const titleEl = card.querySelector('.bf-ui-row-with-ellipsis__title, [class*="title"], [class*="link"], h3, h4');
              const title = titleEl ? titleEl.innerText.trim() : 'Produto Mercado Livre';

              // Extract price
              let priceStr = '0,00';
              const priceMeta = card.querySelector('meta[itemprop="price"]');
              const priceSmallEl = card.querySelector('.bf-ui-price-small, [class*="price-small"]');
              const text = card.innerText || '';

              if (priceMeta && priceMeta.content) {
                priceStr = priceMeta.content.replace('null', ',');
              } else if (priceSmallEl) {
                const priceCentsEl = card.querySelector('.bf-ui-price-small-cents, [class*="price-cents"], [class*="price-small-cents"]');
                const cents = priceCentsEl ? priceCentsEl.innerText.trim() : '00';
                priceStr = `${priceSmallEl.innerText.trim()},${cents}`;
              } else {
                const matchComma = text.match(/R\$\s*([\d.]+,\d{2})/);
                if (matchComma) {
                  priceStr = matchComma[1];
                } else {
                  const matchNoComma = text.match(/R\$\s*(\d+)[\s\xa0]*(\d{2})/);
                  if (matchNoComma) {
                    priceStr = `${matchNoComma[1]},${matchNoComma[2]}`;
                  }
                }
              }

              // Extract date
              let dateStr = '';
              const cardDateMatch = text.match(/\d{1,2}\s+de\s+[a-zçáéíóúâêô]+(?:\s+de\s+\d{4})?/i);
              if (cardDateMatch) {
                dateStr = cardDateMatch[0];
              } else {
                let parent = card.parentElement;
                while (parent && parent !== document.body && !parent.classList.contains('my-purchases-list') && !dateStr) {
                  const parentText = parent.innerText || '';
                  const match = parentText.match(/\d{1,2}\s+de\s+[a-zçáéíóúâêô]+(?:\s+de\s+\d{4})?/i);
                  if (match) {
                    dateStr = match[0];
                  }
                  parent = parent.parentElement;
                }
              }

              results.push({
                orderId: finalId,
                title,
                priceStr,
                dateStr: dateStr || 'Data não encontrada',
                url: href
              });
            }
          }
        }
        return results;
      });

      const processed = pagePurchases.reduce((acc, curr) => {
        if (!acc.some(item => item.orderId === curr.orderId)) {
          acc.push(curr);
        }
        return acc;
      }, []);

      console.log(`Encontradas ${processed.length} compras nesta página.`);
      newPurchases = newPurchases.concat(processed);

      if (autoPage) {
        const nextButton = await page.$('li.andes-pagination__button--next a, li.andes-ui-pagination__button--next a, a[title="Seguinte"], a[title="Próxima"], a[title="Página seguinte"]');
        if (nextButton) {
          try {
            const isVisible = await nextButton.isVisible();
            const isEnabled = await nextButton.isEnabled();
            if (isVisible && isEnabled) {
              console.log("Avançando para a próxima página de histórico...");
              await nextButton.click({ timeout: 5000 });
              pageCount++;
            } else {
              console.log("Botão de próxima página não está ativo. Fim do histórico.");
              hasNextPage = false;
            }
          } catch (clickErr) {
            console.log("Aviso: Botão de próxima página encontrado mas não pôde ser clicado. Fim do histórico.");
            hasNextPage = false;
          }
        } else {
          console.log("Fim do histórico (botão 'Seguinte' não encontrado).");
          hasNextPage = false;
        }
      } else {
        hasNextPage = false;
      }
    }
  }

  // Combine, deduplicate, and save
  const combined = [...existingPurchases, ...newPurchases];
  const uniquePurchases = combined.reduce((acc, curr) => {
    if (!acc.some(item => item.orderId === curr.orderId)) {
      acc.push(curr);
    }
    return acc;
  }, []);

  console.log(`\nExtração finalizada!`);
  console.log(`Total de novas compras capturadas nesta rodada: ${newPurchases.length}`);
  console.log(`Total consolidado no JSON: ${uniquePurchases.length}`);

  fs.writeFileSync(outputPath, JSON.stringify(uniquePurchases, null, 2), 'utf-8');
  console.log(`Dados gravados com sucesso em: ${outputPath}`);

  rl.close();
  await browser.close();
}

main().catch(err => {
  console.error("Erro na execução do script:", err);
  rl.close();
});
