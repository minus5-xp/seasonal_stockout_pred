# Script to fix hardcoded 2024 references in RESUMEN EJECUTIVO FINAL cell

$file = Get-ChildItem -Path $PWD -Filter "*Informe_Aftermarket_Europa*v2.ipynb" | Select-Object -First 1 | Select-Object -ExpandProperty FullName
Write-Host "File path: $file" -ForegroundColor Magenta

Write-Host "Loading notebook..." -ForegroundColor Yellow
$content = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host "Finding cell 50 (RESUMEN EJECUTIVO FINAL)..." -ForegroundColor Yellow
$cell = $content.cells[50]

Write-Host "Original lines:" -ForegroundColor Cyan
Write-Host "Line 24 (Período): $($cell.source[24])"
Write-Host "Line 29 (CAGR text): $($cell.source[29])"  
Write-Host "Line 30 (Índice 2015): $($cell.source[30])"
Write-Host "Line 31 (Índice 2024): $($cell.source[31])"
Write-Host "Line 34 (val_2015 assignment): $($cell.source[34])"
Write-Host "Line 35 (val_2024 assignment): $($cell.source[35])"
Write-Host "Line 36 (if check): $($cell.source[36])"
Write-Host "Line 37 (CAGR calc): $($cell.source[37])"
Write-Host "Line 39 (print 2015): $($cell.source[39])"
Write-Host "Line 40 (print 2024): $($cell.source[40])"

Write-Host "`nApplying fixes..." -ForegroundColor Yellow

# Fix line 24: Período análisis
$cell.source[24] = "print(f`"   • Período análisis: {año_inicio}-{año_fin}`")`n"

# Fix line 29: CAGR text
$cell.source[29] = "    print(f`"   • CAGR G45.3 {año_inicio}-{año_fin}: {df_es_cagr['cagr_pct']:+.2f}%`")`n"

# Fix line 30: Índice inicio
$cell.source[30] = "    print(f`"   • Índice {año_inicio}: {df_es_cagr[f'val_{año_inicio}']:.2f}`")`n"

# Fix line 31: Índice fin
$cell.source[31] = "    print(f`"   • Índice {año_fin}: {df_es_cagr[f'val_{año_fin}']:.2f}`")`n"

# Fix line 34: val_inicio assignment
$cell.source[34] = "    val_inicio = g453_anual[g453_anual['year'] == año_inicio]['g453_index'].values`n"

# Fix line 35: val_fin assignment  
$cell.source[35] = "    val_fin = g453_anual[g453_anual['year'] == año_fin]['g453_index'].values`n"

# Fix line 36: if check
$cell.source[36] = "    if len(val_inicio) > 0 and len(val_fin) > 0:`n"

# Fix line 37-38: CAGR calculation (need to add n_years line)
$cell.source[37] = "        n_years = año_fin - año_inicio`n"
$cell.source[38] = "        cagr_es = ((val_fin[0] / val_inicio[0]) ** (1/n_years) - 1) * 100`n"

# Fix line 40 (was 39): print Índice inicio
$cell.source[40] = "        print(f`"   • Índice {año_inicio}: {val_inicio[0]:.2f}`")`n"

# Fix line 41 (was 40): print Índice fin
$cell.source[41] = "        print(f`"   • Índice {año_fin}: {val_fin[0]:.2f}`")`n"

# Now fix Europa section (lines ~55-70)
# Find the SQL query line
for ($i = 0; $i -lt $cell.source.Count; $i++) {
    if ($cell.source[$i] -match "YEAR\(time_period\) IN \(2015, 2024\)") {
        Write-Host "Found SQL query at line $i" -ForegroundColor Green
        $cell.source[$i] = "  AND YEAR(time_period) IN ({año_inicio}, {año_fin})`n"
    }
    if ($cell.source[$i] -match "# Tenemos 2015 y 2024") {
        Write-Host "Found comment at line $i" -ForegroundColor Green
        $cell.source[$i] = "    if len(df_europa_raw) == 2:  # Tenemos año_inicio y año_fin`n"
    }
    if ($cell.source[$i] -match "val_2015 = df_europa_raw\[df_europa_raw\['year'\] == 2015\]") {
        Write-Host "Found val_2015 Europa at line $i" -ForegroundColor Green
        $cell.source[$i] = "        val_inicio_eur = df_europa_raw[df_europa_raw['year'] == año_inicio]['valor_promedio'].values[0]`n"
    }
    if ($cell.source[$i] -match "val_2024 = df_europa_raw\[df_europa_raw\['year'\] == 2024\]") {
        Write-Host "Found val_2024 Europa at line $i" -ForegroundColor Green
        $cell.source[$i] = "        val_fin_eur = df_europa_raw[df_europa_raw['year'] == año_fin]['valor_promedio'].values[0]`n"
    }
    if ($cell.source[$i] -match "reg_2015 = df_europa_raw") {
        Write-Host "Found reg_2015 at line $i" -ForegroundColor Green
        $cell.source[$i] = "        reg_inicio = df_europa_raw[df_europa_raw['year'] == año_inicio]['registros'].values[0]`n"
    }
    if ($cell.source[$i] -match "reg_2024 = df_europa_raw") {
        Write-Host "Found reg_2024 at line $i" -ForegroundColor Green
        $cell.source[$i] = "        reg_fin = df_europa_raw[df_europa_raw['year'] == año_fin]['registros'].values[0]`n"
    }
    if ($cell.source[$i] -match "paises_2015 = df_europa_raw") {
        Write-Host "Found paises_2015 at line $i" -ForegroundColor Green
        $cell.source[$i] = "        paises_inicio = df_europa_raw[df_europa_raw['year'] == año_inicio]['paises'].values[0]`n"
    }
    if ($cell.source[$i] -match "paises_2024 = df_europa_raw") {
        Write-Host "Found paises_2024 at line $i" -ForegroundColor Green
        $cell.source[$i] = "        paises_fin = df_europa_raw[df_europa_raw['year'] == año_fin]['paises'].values[0]`n"
    }
    if ($cell.source[$i] -match "cagr_eur = \(\(val_2024 / val_2015\) \*\* \(1/9\)") {
        Write-Host "Found CAGR Europa calc at line $i" -ForegroundColor Green
        $cell.source[$i] = "        n_years_eur = año_fin - año_inicio`n"
        $cell.source.Insert($i+1, "        cagr_eur = ((val_fin_eur / val_inicio_eur) ** (1/n_years_eur) - 1) * 100`n")
    }
    if ($cell.source[$i] -match "CAGR G45 \(Eurostat raw\) 2015-2024") {
        Write-Host "Found CAGR print at line $i" -ForegroundColor Green
        $cell.source[$i] = "        print(f`"   • CAGR G45 (Eurostat raw) {año_inicio}-{año_fin}: {cagr_eur:+.2f}%`")`n"
    }
    if ($cell.source[$i] -match "Valor promedio 2015:.*val_2015.*paises_2015.*reg_2015") {
        Write-Host "Found Valor 2015 print at line $i" -ForegroundColor Green
        $cell.source[$i] = "        print(f`"   • Valor promedio {año_inicio}: {val_inicio_eur:.2f} ({paises_inicio} países, {reg_inicio} registros)`")`n"
    }
    if ($cell.source[$i] -match "Valor promedio 2024:.*val_2024.*paises_2024.*reg_2024") {
        Write-Host "Found Valor 2024 print at line $i" -ForegroundColor Green
        $cell.source[$i] = "        print(f`"   • Valor promedio {año_fin}: {val_fin_eur:.2f} ({paises_fin} países, {reg_fin} registros)`")`n"
    }
}

Write-Host "`nSaving notebook..." -ForegroundColor Yellow
$content | ConvertTo-Json -Depth 100 -Compress:$false | Set-Content $file -Encoding UTF8

Write-Host "✅ Notebook updated successfully!" -ForegroundColor Green
Write-Host "`nFixed references:" -ForegroundColor Cyan
Write-Host "  • Período análisis: dynamic"
Write-Host "  • CAGR text: dynamic"
Write-Host "  • Índice prints: dynamic"
Write-Host "  • Variable assignments: val_inicio, val_fin"
Write-Host "  • CAGR calculations: uses n_years"
Write-Host "  • Europa section: all references dynamic"
