# 🏦 **KipuBankV2**

💡 *Bóveda inteligente multi-activo (ETH + USDC) con límites globales y conversión automática a USD mediante Chainlink.*  

Este proyecto forma parte del **examen final del Módulo 3 - Desarrollo Web3**, y está diseñado con fines **educativos** y **profesionales**, aplicando buenas prácticas de **arquitectura, seguridad y documentación NatSpec**.

---

## ✨ **Funcionalidad**

✅ **Depósitos y retiros**  
- Los usuarios pueden depositar **ETH o USDC**.  
- Los retiros están limitados por una cantidad máxima por transacción.  
- Existe un **límite global del banco (bankCap)** expresado en USD (6 decimales).  

🧮 **Conversión automática**  
- Conversión ETH→USD en tiempo real con **Chainlink Data Feed ETH/USD**.  

🔒 **Control de acceso y seguridad**  
- El propietario puede **pausar** operaciones o **actualizar el oráculo**.  
- Protección contra **reentradas**, uso de **Ownable**, **SafeERC20** y **errores personalizados**.  

📊 **Registro contable completo**  
- Saldos individuales (ETH y USDC).  
- Número de depósitos y retiros por usuario.  
- Totales globales del banco (depósitos, retiros y valor acumulado en USD).  
- Eventos emitidos en cada operación.  

---

## 🚀 **Despliegue en Remix**

1. Abrir [Remix IDE](https://remix.ethereum.org).  
2. Crear un nuevo archivo en `/src` llamado `KipuBankV2.sol`.  
3. Copiar el contrato.  
4. Compilar con **Solidity 0.8.26**, activando el optimizer (200 runs).  
5. En *Deploy & Run Transactions*:  
   - Seleccionar **Injected Provider – MetaMask**.  
   - Red: **Ethereum Sepolia**.  

### ⚙️ **Parámetros del constructor**

| Parámetro | Descripción | Ejemplo (Sepolia) |
|------------|--------------|------------------|
| `_owner` | Dirección del propietario | `0xd...` |
| `_usdc` | Contrato USDC testnet | `0x07865c6E87B9F70255377e024ace6630C1Eaa37F` |
| `_ethUsdFeed` | Chainlink ETH/USD Feed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| `_bankCapUSD6` | Límite global (6 decimales) | `1000000000000` → 1.000.000 USD |
| `_withdrawLimitUSD6` | Límite de retiro por transacción | `100000000` → 100 USD |

👉 Presionar **Deploy** y confirmar la transacción.

---

## 🧠 **Interacción con el contrato**

| Función | Descripción |
|----------|--------------|
| `depositETH()` | Deposita ETH en la bóveda (usar el campo *Value* en Remix). |
| `depositUSDC(uint256 amount)` | Deposita USDC (tras aprobar previamente con `approve()`). |
| `withdrawETH(uint256 amount)` | Retira ETH hasta el límite permitido. |
| `withdrawUSDC(uint256 amount)` | Retira saldo en USDC. |
| `getBalanceETH(address user)` | Devuelve el balance ETH del usuario. |
| `getBalanceUSDC(address user)` | Devuelve el balance USDC del usuario. |
| `contractBalance()` | Retorna el balance total del contrato. |
| `setPaused(bool status)` | Pausa o reanuda operaciones (solo propietario). |

---

## 🛡️ **Seguridad y Buenas Prácticas**

- 🧱 **Errores personalizados** en lugar de `require` con texto.  
- 🔁 **Patrón Checks-Effects-Interactions**.  
- 🚫 **Protección Reentrancy Guard**.  
- 🧩 **Control de acceso Ownable**.  
- 💵 **SafeERC20** para manejo seguro de tokens.  
- ⏱️ **Validación de oráculo** mediante heartbeat (`ORACLE_HEARTBEAT = 3600`).  
- 📚 **Documentación NatSpec exhaustiva** en todas las secciones.  
- ⚙️ **Uso de variables `immutable` y `constant`** para optimizar gas y legibilidad.  

---

## 🔗 **Contrato desplegado**

**Dirección:**  
[`0xF70c8d17E9D6907F906d1A95878732774980683E`](https://sepolia.etherscan.io/address/0xF70c8d17E9D6907F906d1A95878732774980683E#code)  

- 🌐 **Red:** Ethereum Sepolia  
- ✅ **Verificado en:** Etherscan  

---

## 💡 **Mejoras respecto a KipuBank v1**

| Área | Versión 1 | Versión 2 |
|------|------------|-----------|
| Activos soportados | Solo ETH | ETH + USDC |
| Límite global | En ETH | En USD (6 decimales) |
| Oráculo | N/A | Chainlink ETH/USD |
| Control de acceso | Ninguno | `Ownable`, función `setPaused` |
| Seguridad | Reentrancy básico | Reentrancy Guard + SafeERC20 |
| Arquitectura | Monolítica | Modular, extensible y escalable |

---
